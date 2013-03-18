#!/usr/bin/env ruby

require 'rubygems'
require 'open-uri' #Allows url's to be opened as files
require 'json' #Github API stores data as JSON
require 'optparse'
require 'igraph'
require 'csv'
require 'github_api'

options={}
OptionParser.new do |opts|
  opts.banner = "Usage: ./sna.rb [options]"

  opts.on("-r", "--rubinius", "Queries rubinius repo") do
    options[:query] = true
    options[:rubinius] = true
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
  attr_accessor :graph
  def initialize(user, repo, month)
    @github = Github.new(oauth_token: "d72762df620b07c1ca9dab8b62b3935087d71e1c")
    @user = user
    @repo = repo
    #Retrieves all necessary info for a repo and sorts it by event type
    tempcsv=CSV.parse(File.read("output.csv"))
    @repo_info = tempcsv[1..-1].collect do |row|
      temphash = {}
      row.each_with_index do |x,i|
        temphash[tempcsv[0][i]] = x
      end
      temphash
    end
    Dir.mkdir("#{@user}_#{@repo}") unless Dir.exists? "#{@user}_#{@repo}"
    0.upto(month) do |m|
      generate_repo_graph(m)
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
    shas = commit_comments.collect{|c| c["comment_commit"]}.uniq
    puts @user
    puts @repo
    commits = shas.collect do |sha|
      begin
        puts sha
        @github.repos.commits.get(@user, @repo, sha)
      rescue Github::Error::NotFound
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
      make_edge(graph, cc["actor"], commit_users[cc["comment_commit"]])
    end

    #Pull down all the issues and events at the same time, because we handle
    #them the same way
    issues_pulls = monthly_repo_info["IssuesEvent"] + monthly_repo_info["PullRequestEvent"]
    #Group the issues and pulls by payload_action because we will be handling
    #closed ones and opened ones differently, and they need to reference
    #each other
    coip = issues_pulls.group_by{|ip| ip["action"]}
    coip.default = []
    open_users_by_number={}
    open_users_by_id={}
    coip["opened"].each do |o|
      open_users_by_number[o["issue_number"]]=o["actor"] if o["issue_number"]
      open_users_by_id[o["issue_id"]]=o["actor"] if o["issue_id"]
    end
    #For PR's and Issues as well as comments, we check the number and id because
    #data format has changed over time in Githubarchive.
    coip["closed"].each do |c|
      if (c["issue_number"] && user=open_users_by_number[c["issue_number"]])
        make_edge(graph, c["actor"], user)
      elsif (c["issue_id"] && user=open_users_by_id[c["issue_id"]])
        make_edge(graph, c["actor"], user)
      end
    end
    issue_comments = monthly_repo_info["IssueCommentEvent"]
    issue_comments.each do |ic|
      if (ic["issue_number"] && user=open_users_by_number[ic["issue_number"]])
        make_edge(graph, ic["actor"], user)
      elsif (ic["issue_id"] && user=open_users_by_id[ic["issue_id"]])
        make_edge(graph, ic["actor"], user)
      end
    end
    pr_comments = monthly_repo_info["PullRequestReviewCommentEvent"]
    pr_comments.each do |pc|
      issue_number = pc["issue_number"] || @github.pull_requests.comments.get(@user, @repo, pc["comment_id"])._links.pull_request.href.match(/\/pulls\/(\d+)/)[1]
      if (user=open_users_by_number[issue_number])
        make_edge(graph, pc["actor"], user)
      end
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
