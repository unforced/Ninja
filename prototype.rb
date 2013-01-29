require 'open-uri' #Allows url's to be opened as files
require 'json' #Github API stores data as JSON
require 'rubygems'
require 'igraph'
require 'github_api'

#A lot of this still needs many more comments.

class String
  def fix_link
    return self.sub(/\{\/\w+\}/,'') #Gets rid of stuff like {/sha} at end of link
  end
end

API_LINK = "https://api.github.com"
REPOS_LINK = "#{API_LINK}/repos"

class RepoGraph
  attr_accessor :graph
  def initialize(user, repo)
    @github = Github.new(oauth_token: "d72762df620b07c1ca9dab8b62b3935087d71e1c")
    @user = user
    @repo = repo
    @repo_link = "#{REPOS_LINK}/#{user}/#{repo}"
    @graph = IGraph.new([],false)
    generate_repo_graph
  end

  def get_json_query(query)
    JSON.parse `bq --format json -q query "#{query}"`
  end

  def get_json(link)
    #Reads in a link to the github API, passing OAUTH token to authenticate
    #Then parses it with JSON and returns the result
    begin
      x=JSON.parse(open(link, "Authorization" => "token d72762df620b07c1ca9dab8b62b3935087d71e1c").read)
    rescue OpenURI::HTTPError #Occasionally throws a 502 error, usually fixed by just trying again
      retry
    end
  end

  def generate_repo_graph
    @repo_info = get_json(@repo_link)
    generate_commit_graph
    generate_pulls_issues_graph
  end

  #This generates a block of code used for iterating through comments and adding
  #vertices and edges for them.
  def comments_proc(user)
    Proc.new do |comment|
      comment_user = comment.user.login
      @graph.add_vertex(comment_user)
      if @graph.are_connected(user, comment_user)
        #If the edge exists, just add 1 to weight
        @graph.set_edge_attr(user, comment_user,
                             @graph.get_edge_attr(user,comment_user)+1)
      elsif user != comment_user
        #Otherwise, add the edge and set weight to 1
        @graph.add_edge(user, comment_user)
        @graph.set_edge_attr(user, comment_user, 1)
      end
    end
  end

  def generate_pulls_issues_graph
    #Gets all issues and pulls(github stores them together)
    all_pulls = @github.pull_requests.list(@user, @repo, state: "closed", per_page: 100)
    pulls.each_page do |page|
      page.each do |pull|
        pull_submitter = pull.user.login
        @graph.add_vertex(pull_submitter)
        comments = @github.pull_requests.comments.list(@user,@repo,request_id: pull.number)
        pull_comments_proc=comments_proc(pull_submitter)
        comments.each_page{|page| page.each(&pull_comments_proc)} #Passes pull_comments_proc as block.
        if pull.state=="closed"
          issue = @github.issues.get(@user, @repo, pull.number)
          closer = issue.closed_by.login
          @graph.add_vertex(closer)
          if @graph.are_connected(pull_submitter, closer)
            #If the edge exists, just add 1 to weight
            @graph.set_edge_attr(pull_submitter, closer,
                                 @graph.get_edge_attr(pull_submitter,closer)+1)
          elsif pull_submitter != closer
            #Otherwise, add the edge and set weight to 1
            @graph.add_edge(pull_submitter, closer)
            @graph.set_edge_attr(pull_submitter, closer, 1)
          end
        end
      end
      page+=1
    end
  end

  def generate_commit_graph
    commits = @github.repos.commits.list(@user, @repo, per_page: 100)
    commits.each_page do |page|
      page.each do |commit|
        committer = commit.committer ? commit.committer.login : commit.commit.commiter.email
        @graph.add_vertex(committer)
        comments=@github.repo.comments.list(@user, @repo, sha: commit.sha)
        commit_comments


    #Gathers all the shas that are the head of all the branches first
    #Then iterate through all of them, going to the commit url
    #This url shows the previous 100 commits on that branch
    #Iterate through all of them, skipping if they've been checked and adding
    #them to shas_checked afterwards.
    #If there are 100 commits on the page shown, add the last one to the shas
    #So that it can be checked from there
              @graph.add_vertex(commit_user)
              shas_checked << commit["sha"]
              @@comment_pages+=1
              comments = get_json(commit["comments_url"])
              commit_comments_proc = comments_proc(commit_user)
              comments.each(&commit_comments_proc)
            end
          end
        end
      end
    end
  end
end

#All of these @@'s are just for testing purposes
@@count=0
@@clock=Time.now
@@lookuptime=0
@@pagelookups=0
@@comment_pages=0
@@commit_pages=0
g=RepoGraph.new(ARGV[0], ARGV[1])
puts "Total time was #{Time.now-@@clock}"
puts "Lookup time was #{@@lookuptime}"
puts "Total lookups was #{@@pagelookups}"
puts "Total comment lookups was #{@@comment_pages}"
puts "Total commit lookups was #{@@commit_pages}"
puts "Total commits was #{@@count}"
puts g.graph.edges(1).count
