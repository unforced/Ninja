require 'rubygems'
require 'open-uri' #Allows url's to be opened as files
require 'json' #Github API stores data as JSON
require 'github_api'
require 'optparse'
require 'igraph'

options={}
OptionParser.new do |opts|
  opts.banner = "Usage: prototype.rb [options]"

  opts.on("-u", "--update_repo_list [NUM]", Integer, "Update repository list and info, with number of repos(default 100)") do |n|
    options[:update]=true
    options[:num]=n||100
  end

  opts.on("--repo [USER/REPO]", String, "Generate graph for user/repo") do |r|
    options[:query]=true
    options[:user], options[:repo] = r.split('/')
  end

  opts.on("--output [OUTPUTFILE]", String, "File to output to(defaults to sample.graphml)") do |o|
    options[:output] = o
  end

  opts.on_tail("-h", "--help", "Show this help message") do
    puts opts
    exit
  end
end.parse!

options[:output]||="sample.graphml"

class RepoGraph
  MAX_REPOS=100000
  attr_accessor :graph
  def initialize(user, repo)
    @github = Github.new(oauth_token: "d72762df620b07c1ca9dab8b62b3935087d71e1c")
    @user = user
    @repo = repo
    @graph = IGraph.new([],false)
    generate_repo_graph
  end

  #Retrieves the url's of the top 100 repositories
  #Processes approximately 3.5GB($0.10) of data.
  def self.get_top_repos(n=100)
    query = <<-EOF
    SELECT repository_url, MAX(repository_forks) as num_forks
    FROM [githubarchive:github.timeline]
    GROUP BY repository_url
    ORDER BY num_forks DESC
    LIMIT #{n};
    EOF
    `bq rm -f mygithubarchives.top_repos`
    `bq query --destination_table=mygithubarchives.top_repos "#{query}"`
  end

  #Retrieves all necessary info on the top repositories
  #Processes approximately 12GB($0.40) of data
  def self.get_top_repos_info(repo_name="top_repos")
    query = <<-EOF
    SELECT actor, payload_action, type, payload_commit, payload_number, url, repository_url, repository_name, repository_owner
    FROM [githubarchive:github.timeline]
    WHERE repository_url IN (SELECT repository_url FROM mygithubarchives.top_repos)
    AND (type='CommitCommentEvent' OR type='IssueCommentEvent' OR type='IssuesEvent' OR type='PullRequestEvent' OR type='PullRequestReviewCommentEvent');
    EOF
    `bq rm -f mygithubarchives.top_repo_info`
    `bq query --destination_table=mygithubarchives.top_repo_info "#{query}"`
  end

  def get_json_query(query)
    #Makes the call to big query and parses the JSON returned
    JSON.parse `bq --format json -q query --max_rows #{MAX_REPOS} "#{query}"`
  end

  def generate_repo_graph
    #This query will use approximately 140MB(<$0.01) of data
    query = <<-EOF
    SELECT *
    FROM [mygithubarchives.top_repo_info]
    WHERE repository_name='#{@repo}' AND repository_owner='#{@user}'
    EOF
    #Retrieves all necessary info for a repo and sorts it by event type
    @repo_info=get_json_query(query).group_by{|e| e["type"]}
    commit_comments = @repo_info["CommitCommentEvent"] || []
    #Get all the shas and commits first, and make them uniq, to prevent
    #retrieving the same one multiple times
    shas = commit_comments.collect{|c| c["payload_commit"]}.uniq || []
    commits = shas.collect do |sha|
      begin
        @github.repos.commits.get(@user, @repo, sha)
      rescue
        nil
      end
    end.compact.uniq || []
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
      make_edge(cc["actor"], commit_users[cc["payload_commit"]])
    end

    #Pull down all the issues and events at the same time, because we handle
    #them the same way
    issues_pulls = (@repo_info["IssuesEvent"] || []) + (@repo_info["PullRequestEvent"] || [])
    #Group the issues and pulls by payload_action because we will be handling
    #closed ones and opened ones differently, and they need to reference
    #each other
    coip = issues_pulls.group_by{|ip| ip["payload_action"]}
    open_users={}
    coip["opened"].each{|o| open_users[o["payload_number"]]=o["actor"]} if coip["opened"]
    coip["closed"].each{|c| make_edge(c["actor"], open_users[c["payload_number"]])} if coip["closed"]
    issue_comments = @repo_info["IssueCommentEvent"] || []
    #Have to retrieve payload number from url for next two because it does not show up normally
    issue_comments.each do |ic|
      make_edge(ic["actor"], open_users[ic["url"].match(/\/issues\/(\d+)#/)[1]])
    end
    pr_comments = @repo_info["PullRequestReviewCommentEvent"] || []
    pr_comments.each do |pc|
      make_edge(pc["actor"], open_users[pc["url"].match(/\/pull\/(\d+)#/)[1]])
    end
  end

  def make_edge(u1, u2)
    u1={"name"=>u1}
    u2={"name"=>u2}
    @graph.add_vertices([u1,u2])
    if @graph.are_connected(u1,u2)
      @graph.set_edge_attr(u1,u2,{"weight"=>@graph.get_edge_attr(u1,u2)["weight"]+1})
    else
      @graph.add_edges([u1,u2],[{"weight"=>1}])
    end
  end
end

if options[:update]
  RepoGraph.get_top_repos(options[:num])
  RepoGraph.get_top_repos_info
end

if options[:query]
  g=RepoGraph.new(options[:user], options[:repo])
  g.graph.write_graph_graphml(File.open(options[:output],'w'))
end
