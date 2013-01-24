require 'open-uri' #Allows url's to be opened as files
require 'json' #Github API stores data as JSON
require 'rubygems'
require 'graphviz'

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
    @graph = GraphViz.new(:G)
    generate_repo_graph
  end

  def get_json(link)
    #Reads in a link to the github API, passing OAUTH token to authenticate
    #Then parses it with JSON and returns the result
    JSON.parse(open(link, "Authorization" => "token f9badac33670497d4e60040948f9bb66c9801705").read)
  end

  def generate_repo_graph
    repo_info = get_json(@repo_link)
    base_commit_url = "#{@repo_link}/commits?per_page=100&sha="
    branches = get_json(repo_info["branches_url"].fix_link)
    shas = branches.collect{|b| b['commit']['sha']}.uniq
    shas_checked = []
    #Gathers all the shas that are the head of all the branches first
    #Then iterate through all of them, going to the commit url
    #This url shows the previous 100 commits on that branch
    #Iterate through all of them, skipping if they've been checked and adding
    #them to shas_checked afterwards.
    #If there are 100 commits on the page shown, add the last one to the shas
    #So that it can be checked from there
    count=0
    until shas.empty?
      if !shas_checked.include?(sha=shas.pop)
        commits = get_json("#{base_commit_url}#{sha}")
        commits.each_with_index do |commit, index|
          if index==99
            shas << commit["sha"]
          else
            unless shas_checked.include? commit["sha"]
              count+=1
              if commit["committer"]
                commit_user = commit["committer"]["login"]
              else
                commit_user = commit["commit"]["committer"]["email"]
              end
              @graph.add_nodes(commit_user) unless @graph.find_node(commit_user)
              shas_checked << commit["sha"]
              if commit["commit"]["comment_count"] > 0
                comments = get_json(commit["comments_url"])
                comments.each do |comment|
                  comment_user = comment["user"]["login"]
                  @graph.add_nodes(comment_user) unless @graph.find_node(comment_user)

                  @graph.add_edges(commit_user, comment_user) unless commit_user==comment_user
                end
              end
            end
          end
        end
      end
    end
    puts count
  end
end

g=RepoGraph.new(ARGV[0], ARGV[1])
g.graph.output(:png => "sample.png")
