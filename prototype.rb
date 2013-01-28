require 'open-uri' #Allows url's to be opened as files
require 'json' #Github API stores data as JSON
require 'rubygems'
require 'igraph'

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
    @user = user
    @repo = repo
    @repo_link = "#{REPOS_LINK}/#{user}/#{repo}"
    @graph = IGraph.new([],false)
    generate_repo_graph
  end

  def get_json(link)
    @@pagelookups+=1
    clock=Time.now
    #Reads in a link to the github API, passing OAUTH token to authenticate
    #Then parses it with JSON and returns the result
    begin
      x=JSON.parse(open(link, "Authorization" => "token f9badac33670497d4e60040948f9bb66c9801705").read)
    rescue OpenURI::HTTPError #Occasionally throws a 502 error, usually fixed by just trying again
      retry
    end
    @@lookuptime+=Time.now-clock
    x
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
      comment_user = comment["user"]["login"]
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
    open_pulls_url = "#{@repo_link}/issues?per_page=100&state=open&page="
    page=1
    until (pulls=get_json("#{open_pulls_url}#{page}")).empty?
      pulls.each do |pull|
        pull_submitter = pull["user"]["login"]
        @graph.add_vertex(pull_submitter)
        comments = get_json(pull["comments_url"])
        pull_comments_proc=comments_proc(pull_submitter)
        comments.each(&pull_comments_proc) #Passes pull_comments_proc as block.
        if pull["state"]=="closed"
          issue = get_json(pull["url"])
          closer = issue["closed_by"]["login"]
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
    base_commit_url = "#{@repo_link}/commits?per_page=100&sha="
    branches = get_json(@repo_info["branches_url"].fix_link)
    shas = branches.collect{|b| b['commit']['sha']}.uniq
    shas_checked = []
    #Gathers all the shas that are the head of all the branches first
    #Then iterate through all of them, going to the commit url
    #This url shows the previous 100 commits on that branch
    #Iterate through all of them, skipping if they've been checked and adding
    #them to shas_checked afterwards.
    #If there are 100 commits on the page shown, add the last one to the shas
    #So that it can be checked from there
    until shas.empty?
      if !shas_checked.include?(sha=shas.pop)
        @@commit_pages += 1
        commits = get_json("#{base_commit_url}#{sha}")
        commits.each_with_index do |commit, index|
          if index==99
            shas << commit["sha"]
          else
            unless shas_checked.include? commit["sha"]
              @@count+=1
              if commit["committer"]
                commit_user = commit["committer"]["login"]
              else
                commit_user = commit["commit"]["committer"]["email"]
              end
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
