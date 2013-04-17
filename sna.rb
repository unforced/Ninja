#!/usr/bin/env ruby

require 'google/api_client'
require 'github_api'
require 'optparse'
require 'igraph'

options={}
OptionParser.new do |opts|
  opts.banner = "Usage: ./sna.rb [options]"

  opts.on("--update_n [NUMBER_REPOS]", Integer, "Updates the top N repositories(default 100)") do |n|
    options[:update] = n || 100
  end

  opts.on("-n", "--number [NUMBER_REPOS]", Integer, "Query the top N repositories(default 100)") do |n|
    options[:query] = true
    options[:number] = n || 100
  end

  opts.on("-m", "--month", Integer, "Query monthly snapshots back to 4/2012") do
    options[:month] = true
  end

  opts.on_tail("-h", "--help", "Show this help message") do
    puts opts
    exit
  end
end.parse!

class RepoGraph
  MAX_REPOS=100000
  attr_accessor :graph
  def initialize(user, repo, by_month)
    @github = Github.new(oauth_token: "d72762df620b07c1ca9dab8b62b3935087d71e1c")
    @client = Google::APIClient.new(application_name: "SNA", application_version: "0.5")
    @bq = @client.discovered_api("bigquery", "v2")
    key = Google::APIClient::PKCS12.load_key("client.p12", "notasecret")
    @client.authorization = Signet::OAuth2::Client.new(token_credential_uri: 'https://accounts.google.com/o/oauth2/token',
                                                       audience: 'https://accounts.google.com/o/oauth2/token',
                                                       scope: 'https://www.googleapis.com/auth/bigquery',
                                                       issuer: '1017723978940@developer.gserviceaccount.com',
                                                       signing_key: key)
    @client.authorization.fetch_access_token!
    @user = user
    @repo = repo
    @users = {}
    @uid = 0
    #This query will use <1MB of data and retrieve all the info on our given
    #repo. This will be changed back later to allow any repo
    query = <<-EOF
    SELECT *
    FROM [mygithubarchives.top_repo_info]
    WHERE repository_owner='#{user}' AND repository_name='#{repo}';
    EOF
    #Retrieves all necessary info for a repo and sorts it by event type
    @repo_info, @repo_schema = get_json_query(query)
    Dir.mkdir("#{@user}_#{@repo}") unless File.exists?("#{@user}_#{@repo}")
    data_start = Date.new(2012,4)
    months = 1
    if by_month
      months += (Date.today.year - data_start.year)*12 + (Date.today.month - data_start.month)
    end
    months.times do |m|
      generate_repo_graph(m)
    end
  end

  #Retrieves the url's of the top 100 repositories in April
  #Retrieves all necessary info on the top repositories
  #Processes approximately 15GB of data
  def self.update_top(n)
    query = <<-EOF
    SELECT repository_url, repository_name, repository_owner, MAX(repository_forks) as num_forks
    FROM [githubarchive:github.timeline]
    WHERE repository_name!='' AND repository_owner!='' AND MONTH(TIMESTAMP(created_at)) == 4 AND YEAR(TIMESTAMP(created_at)) == 2012
    GROUP BY repository_url, repository_name, repository_owner
    ORDER BY num_forks DESC
    LIMIT #{n};
    EOF
    `bq rm -f mygithubarchives.top_repos`
    `bq query --destination_table=mygithubarchives.top_repos "#{query}"`
    query2 = <<-EOF
    SELECT actor, created_at, payload_action, type, payload_commit, payload_number, url, repository_url, repository_name, repository_owner
    FROM [githubarchive:github.timeline]
    WHERE repository_url IN (SELECT repository_url FROM mygithubarchives.top_repos) AND PARSE_UTC_USEC(created_at) >= PARSE_UTC_USEC('2012-04-01 00:00:00')
    AND (type='CommitCommentEvent' OR type='IssueCommentEvent' OR type='IssuesEvent' OR type='PullRequestEvent' OR type='PullRequestReviewCommentEvent');
    EOF
    `bq rm -f mygithubarchives.top_repo_info`
    `bq query --destination_table=mygithubarchives.top_repo_info "#{query2}"`
  end

  def self.get_top(n, m)
    query = <<-EOF
    SELECT repository_url, repository_name, repository_owner, num_forks
    FROM [mygithubarchives.top_repos]
    ORDER BY num_forks DESC
    LIMIT #{n}
    EOF
    top=get_json_query(query)
    top.each do |r|
      RepoGraph.new(r["repository_owner"], r["repository_name"], m)
      puts "Finished #{repository_owner}_#{repository_name}"
    end
  end

  #Schema:
  #[actor, created_at, payload_action, payload_commit, payload_number,
  #repository_name, repository_owner, repository_url, type, url]
  def get_json_query(query)
    #Makes the call to big query and parses the JSON returned
    data = @client.execute(api_method: @bq.jobs.query, body_object: {query: query},
                           parameters: {projectId: "githubsna"}).data
    puts "Used #{data["total_bytes_processed"]} bytes of data"
    puts "Returned #{data["total_rows"]} rows"
    schema = {}
    data.schema.fields.each_with_index do |f,i|
      schema[f.name]=i
    end
    [data.rows, schema]
  end

  def r(query_result, key)
    query_result.f[@repo_schema[key]].v
  end

  def generate_repo_graph(month)
    graph = IGraph.new([],false)
    #Retrieve snapshots at the first day of the month
    start_date = Date.new(Date.today.year, Date.today.month).prev_month(month)
    #Initialize nodes first
    graph.add_vertices(@users.values)
    monthly_repo_info = @repo_info.select do |e|
      begin
        Date.parse(r(e,"created_at")) <
        Date.today.prev_month(month)
      rescue
        p e
        exit
      end
    end.group_by{|e| r(e,"type")}
    monthly_repo_info.default=[]
    commit_comments = monthly_repo_info["CommitCommentEvent"]
    #Get all the shas and commits first, and make them uniq, to prevent
    #retrieving the same one multiple times
    shas = commit_comments.collect{|c| r(c, "payload_commit")}.uniq
    commits = shas.collect do |sha|
      begin
        @github.repos.commits.get(@user, @repo, sha)
      rescue
        nil
      end
    end.compact.uniq
    commit_users = {}
    #Sorts the commits by sha for quick retrieval
    commits.each do |c|
      begin
        commit_users[c["sha"]]=c["committer"]["login"]
      rescue
        commit_users[c["sha"]]=c["commit"]["committer"]["name"]
      end
    end
    #Iterate through all comments, making an edge between the comment creator
    #and the committer
    commit_comments.each do |cc|
      make_edge(graph, r(cc,"actor"), commit_users[r(cc,"payload_commit")])
    end

    #Pull down all the issues and events at the same time, because we handle
    #them the same way
    issues_pulls = monthly_repo_info["IssuesEvent"] + monthly_repo_info["PullRequestEvent"]
    #Group the issues and pulls by payload_action because we will be handling
    #closed ones and opened ones differently, and they need to reference
    #each other
    coip = issues_pulls.group_by{|ip| r(ip,"payload_action")}
    coip.default = []
    open_users={}
    coip["opened"].each{|o| open_users[r(o,"payload_number")]=r(o,"actor")}
    coip["closed"].each{|c| make_edge(graph, r(c,"actor"), open_users[r(c,"payload_number")])}
    issue_comments = monthly_repo_info["IssueCommentEvent"]
    #Have to retrieve payload number from url for next two because it does not show up normally
    issue_comments.each do |ic|
      make_edge(graph, r(ic,"actor"), open_users[r(ic,"url").match(/\/issues\/(\d+)#/)[1]])
    end
    pr_comments = monthly_repo_info["PullRequestReviewCommentEvent"]
    pr_comments.each do |pc|
      make_edge(graph, r(pc,"actor"), open_users[r(pc,"url").match(/\/pull\/(\d+)#/)[1]])
    end
    graph.write_graph_graphml(File.open("#{@user}_#{@repo}/#{@user}_#{@repo}_#{start_date.year}_#{start_date.month.to_s.rjust(2,'0')}.graphml", 'w'))
  end

  def make_edge(graph, u1n, u2n)
    return if u1n==u2n
    @users[u1n] ||= (@uid+=1)
    @users[u2n] ||= (@uid+=1)
    u1 = @users[u1n]
    u2 = @users[u2n]
    graph.add_vertices([u1,u2])
    if graph.are_connected(u1,u2)
      graph.set_edge_attr(u1,u2,{"weight"=>graph.get_edge_attr(u1,u2)["weight"]+1})
    else
      graph.add_edges([u1,u2],[{"weight"=>1}])
    end
  end
end

if options[:update]
  if options[:update].class == Fixnum
    RepoGraph.update_top(options[:update])
  else
    raise ArgumentError
  end
end

if options[:query]
  if options[:number]
    RepoGraph.get_top(options[:number], options[:month])
  else
    raise ArgumentError
  end
end
