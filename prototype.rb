require 'rubygems'
require 'open-uri' #Allows url's to be opened as files
require 'json' #Github API stores data as JSON
require 'github_api'
require 'graphviz' #Allows graph visualization(Helps for debugging)

MAX_REPOS=100000

class RepoGraph
  attr_accessor :graph
  def initialize(user, repo)
    @github = Github.new(oauth_token: "d72762df620b07c1ca9dab8b62b3935087d71e1c")
    @user = user
    @repo = repo
    @graph = GraphViz.new(:G)
    generate_repo_graph
  end

  def get_json_query(query)
    #Makes the call to big query and parses the JSON returned
    JSON.parse `bq --format json -q query --max_rows #{MAX_REPOS} "#{query}"`
  end

  def generate_repo_graph
    query = <<-EOF
    SELECT *
    FROM [mygithubarchives.top_repo_info]
    WHERE repository_name='#{@repo}' AND repository_owner='#{@user}'
    EOF
    clock=Time.now
    #Retrieves all necessary info for a repo and sorts it by event type
    @repo_info=get_json_query(query).group_by{|e| e["type"]}
    puts "Retrieval took #{Time.now-clock} seconds"
    commit_comments = @repo_info["CommitCommentEvent"]
    #Get all the shas and commits first, and make them uniq, to prevent
    #retrieving the same one multiple times
    shas = commit_comments.collect{|c| c["payload_commit"]}.uniq
    commits = shas.collect{|sha| @github.repos.commits.get(@user, @repo, sha)}.uniq
    commit_users = {}
    #Sorts the commits by sha for quick retrieval
    commits.each do |c|
      commit_users[c["sha"]]=c["committer"]["login"]
    end
    #Iterate through all comments, making an edge between the comment creator
    #and the committer
    commit_comments.each do |cc|
      make_edge(cc["actor"], commit_users[cc["payload_commit"]])
    end

    #Pull down all the issues and events at the same time, because we handle
    #them the same way
    issues_pulls = @repo_info["IssuesEvent"] + @repo_info["PullRequestEvent"]
    #Group the issues and pulls by payload_action because we will be handling
    #closed ones and opened ones differently, and they need to reference
    #each other
    coip = issues_pulls.group_by{|ip| ip["payload_action"]}
    open_users={}
    coip["opened"].each do |o|
      open_users[o["payload_number"]]=o["actor"]
    end
    coip["closed"].each do |c|
      make_edge(c["actor"], open_users[c["payload_number"]])
    end
  end

  def make_edge(u1, u2)
    begin
      @graph.add_edges(u1.to_s,u2.to_s)
    rescue
      puts u1, u2
    end
  end
end

$clock=Time.now
g=RepoGraph.new(ARGV[0], ARGV[1])
g.graph.output(png: "sample.png")
puts "It took #{Time.now-$clock} seconds"
