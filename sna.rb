#!/usr/bin/env ruby

require 'rubygems'
require 'open-uri' #Allows url's to be opened as files
require 'json' #Github API stores data as JSON
require 'github_api'
require 'optparse'
require 'igraph'

options={}
OptionParser.new do |opts|
  opts.banner = "Usage: ./sna.rb [options]"

  opts.on("--update_rubinius", "Updates rubinius repo in BigQuery") do
    options[:update] = true
  end

  opts.on("--update_n [NUMBER_REPOS]", Integer, "Updates the top N repositories(default 100)") do |n|
    options[:update] = n || 100
  end

  opts.on("-r", "--rubinius", "Queries rubinius repo") do
    options[:query] = true
    options[:rubinius] = true
    options[:month] ||= 0
  end

  opts.on("-n", "--number [NUMBER_REPOS]", Integer, "Query the top N repositories(default 100)") do |n|
    options[:query] = true
    options[:number] = n || 100
    options[:month] ||= 0
  end

  opts.on("-m", "--month [MONTHS]", Integer, "Query monthly snapshots MONTHS times(default 12)") do |m|
    options[:month] = m || 12
  end

  opts.on_tail("-h", "--help", "Show this help message") do
    puts opts
    exit
  end
end.parse!

class RepoGraph
  MAX_REPOS=100000
  attr_accessor :graph
  def initialize(user, repo, month)
    @github = Github.new(oauth_token: "d72762df620b07c1ca9dab8b62b3935087d71e1c")
    @user = user
    @repo = repo
    #This query will use <1MB of data and retrieve all the info on our given
    #repo. This will be changed back later to allow any repo
    query = <<-EOF
    SELECT *
    FROM [mygithubarchives.top_repo_info]
    WHERE repository_owner='#{user}' AND repository_name='#{repo}';
    EOF
    #Retrieves all necessary info for a repo and sorts it by event type
    @repo_info=RepoGraph.get_json_query(query)
    Dir.mkdir("#{@user}_#{@repo}")
    0.upto(month) do |m|
      generate_repo_graph(m)
    end
  end

  def self.update_rubinius
    query = <<-EOF
    SELECT actor, created_at, payload_action, type, payload_commit, payload_number, url, repository_url, repository_name, repository_owner
    FROM [githubarchive:github.timeline]
    WHERE repository_name='rubinius' AND repository_owner='rubinius'
    AND (type='CommitCommentEvent' OR type='IssueCommentEvent' OR type='IssuesEvent' OR type='PullRequestEvent' OR type='PullRequestReviewCommentEvent');
    EOF
    `bq rm -f mygithubarchives.rubinius_info`
    `bq query --destination_table=mygithubarchives.rubinius_info "#{query}"`
  end

  #Retrieves the url's of the top 100 repositories
  #Retrieves all necessary info on the top repositories
  #Processes approximately 15GB of data
  def self.update_top(n)
    query = <<-EOF
    SELECT repository_url, repository_name, repository_owner, MAX(repository_forks) as num_forks
    FROM [githubarchive:github.timeline]
    WHERE repository_name!='' AND repository_owner!=''
    GROUP BY repository_url, repository_name, repository_owner
    ORDER BY num_forks DESC
    LIMIT #{n};
    EOF
    `bq rm -f mygithubarchives.top_repos`
    `bq query --destination_table=mygithubarchives.top_repos "#{query}"`
    query2 = <<-EOF
    SELECT actor, created_at, payload_action, type, payload_commit, payload_number, url, repository_url, repository_name, repository_owner
    FROM [githubarchive:github.timeline]
    WHERE repository_url IN (SELECT repository_url FROM mygithubarchives.top_repos)
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
    top=RepoGraph.get_json_query(query)
    top.each do |r|
      RepoGraph.new(r["repository_owner"], r["repository_name"], m)
      puts "Finished #{repository_owner}_#{repository_name}"
    end
  end

  def self.get_json_query(query)
    #Makes the call to big query and parses the JSON returned
    begin
      JSON.parse `bq --format json -q query --max_rows #{MAX_REPOS} "#{query}"`
    rescue
      puts query
      exit
    end
  end

  def generate_repo_graph(month)
    graph = IGraph.new([],false)
    monthly_repo_info = @repo_info.select{|e| Date.parse(e["created_at"]) <
      Date.today.prev_month(month)}.group_by{|e| e["type"]}
    monthly_repo_info.default=[]
    commit_comments = monthly_repo_info["CommitCommentEvent"]
    #Get all the shas and commits first, and make them uniq, to prevent
    #retrieving the same one multiple times
    shas = commit_comments.collect{|c| c["payload_commit"]}.uniq
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
      make_edge(graph, cc["actor"], commit_users[cc["payload_commit"]])
    end

    #Pull down all the issues and events at the same time, because we handle
    #them the same way
    issues_pulls = monthly_repo_info["IssuesEvent"] + monthly_repo_info["PullRequestEvent"]
    #Group the issues and pulls by payload_action because we will be handling
    #closed ones and opened ones differently, and they need to reference
    #each other
    coip = issues_pulls.group_by{|ip| ip["payload_action"]}
    coip.default = []
    open_users={}
    coip["opened"].each{|o| open_users[o["payload_number"]]=o["actor"]}
    coip["closed"].each{|c| make_edge(graph, c["actor"], open_users[c["payload_number"]])}
    issue_comments = monthly_repo_info["IssueCommentEvent"]
    #Have to retrieve payload number from url for next two because it does not show up normally
    issue_comments.each do |ic|
      make_edge(graph, ic["actor"], open_users[ic["url"].match(/\/issues\/(\d+)#/)[1]])
    end
    pr_comments = monthly_repo_info["PullRequestReviewCommentEvent"]
    pr_comments.each do |pc|
      make_edge(graph, pc["actor"], open_users[pc["url"].match(/\/pull\/(\d+)#/)[1]])
    end
    graph.write_graph_graphml(File.open("#{@user}_#{@repo}/#{@user}_#{@repo}_#{month}.graphml", 'w'))
  end

  def make_edge(graph, u1, u2)
    u1={"name"=>u1}
    u2={"name"=>u2}
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
  elsif options[:update] == :rubinius
    RepoGraph.update_rubinius
  else
    raise ArgumentError
  end
end

if options[:query]
  if options[:rubinius]
    RepoGraph.new("rubinius", "rubinius", options[:month])
  elsif options[:number]
    RepoGraph.get_top(options[:number], options[:month])
  else
    raise ArgumentError
  end
end
