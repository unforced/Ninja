#!/usr/bin/env ruby

require 'optparse'
require 'csv'
require 'json'
require 'date'

options={}
OptionParser.new do |opts|
  opts.banner = "Usage: ./event-stream.rb [options]"

  opts.on("-n [NUMBER_REPOS]", Integer, "Query the top N repositories(default 100)") do |n|
    options[:n]=n
  end

  opts.on("-u", "Update top_repos list for N repositories, specified with -n") do
    options[:u]=true
  end

  opts.on("-e", "Queries for event stream") do
    options[:e]=true
  end

  opts.on("-m", "Split event stream by months") do
    options[:m]=true
  end

  opts.on("-l", "Limit to Push, PullRequest, Issue events") do
    options[:l]=true
  end

  opts.on("-t", "Include timestamps for event stream") do
    options[:t]=true
  end

  opts.on("-f", "Queries for fork stream") do
    options[:f]=true
  end

  opts.on_tail("-h", "--help", "Show this help message") do
    puts opts
    exit
  end
end.parse!

def update_top(n)
  query = <<-EOF
SELECT repository_url, MAX(repository_forks) as num_forks
FROM [githubarchive:github.timeline]
WHERE repository_name!='' AND repository_owner!='' AND MONTH(TIMESTAMP(created_at)) == 4 AND YEAR(TIMESTAMP(created_at)) == 2012
GROUP BY repository_url
ORDER BY num_forks DESC
LIMIT #{n};
  EOF
  %x{bq rm -f mygithubarchives.top_#{n}_repos}
  puts "Beginning top_repos query"
  clock = Time.now
  %x{bq query --destination_table=mygithubarchives.top_#{n}_repos "#{query}"}
  puts "Finished top_repos query in #{Time.now-clock}"
end

def get_fork_stream(n)
  query = <<-EOF
SELECT T.repository_url AS url, M.num_forks AS max_forks, MONTH(TIMESTAMP(T.created_at)) AS month,
YEAR(TIMESTAMP(T.created_at)) AS year, MAX(T.repository_forks) AS forks
FROM githubarchive:github.timeline AS T
JOIN mygithubarchives.top_#{n}_repos AS M ON T.repository_url=M.repository_url
WHERE PARSE_UTC_USEC(created_at) >= PARSE_UTC_USEC('2012-04-01 00:00:00')
GROUP BY url, max_forks, year, month
ORDER BY max_forks DESC, url ASC, year DESC, month DESC;
  EOF
  puts "Beginning fork_stream query"
  clock = Time.now
  output = `bq --format json -q query --max_rows 99999999 "#{query}"`
  puts "Finished query in #{Time.now-clock}"
  puts "Parsing JSON"
  clock = Time.now
  x = JSON.parse(output).group_by{|a| a["url"]}
  puts "Finished parsing in #{Time.now-clock}"
  puts "Writing to file"
  clock = Time.now
  CSV.open("fork-stream-#{n}.csv", 'w') do |csv|
    monthsyears = x.values.max_by{|a| a.length}.collect{|a| [a["month"],a["year"]]}.reverse
    csv << ["url"] + monthsyears.collect{|a| a.join("/")}
    x.each do |k,v|
      i=0
      v = v.reverse
      forks = monthsyears.collect do |a|
        if v[i] && a[0]==v[i]["month"] && a[1]==v[i]["year"]
          i+=1
          v[i-1]["forks"]
        else
          "N/A"
        end
      end
      csv << [k.match(/https:\/\/github.com\/(.*)/)[1]] + forks
    end
  end
  puts "Finished writing in #{Time.now-clock}"
end

module Enumerable
  def customsort(*args)
    sort do |a,b|
      i, res = -1, 0
      res = a[0][i]<=>b[0][i] until !res.zero? or (i+=1)==a[0].size
      args[i] ? res : -res
    end
  end
end

def get_event_stream(n,m=false,l=false,t=false)
  query = <<-EOF
SELECT T.repository_url AS url, M.num_forks AS forks, T.created_at AS timestamp, T.type AS event
FROM githubarchive:github.timeline AS T
JOIN mygithubarchives.top_#{n}_repos AS M ON T.repository_url=M.repository_url
WHERE PARSE_UTC_USEC(created_at) >= PARSE_UTC_USEC('2012-04-01 00:00:00')
AND PARSE_UTC_USEC(created_at) < PARSE_UTC_USEC('2013-04-01 00:00:00')
#{"AND (T.type='PushEvent' OR T.type='PullRequestEvent' OR T.type='IssuesEvent')" if l}
ORDER BY forks DESC, url ASC, timestamp ASC;
  EOF
  puts "Beginning event_stream query"
  clock = Time.now
  if File.exists?("temp-#{n}-#{l}.json")
    output = File.read("temp-#{n}-#{l}.json")
  else
    output = `bq --format json -q query --max_rows 99999999 "#{query}"`
    File.open("temp-#{n}-#{l}.json",'w'){|f| f.puts output}
  end
  puts "Finished query in #{Time.now-clock}"
  puts "Parsing JSON"
  clock = Time.now
  x = JSON.parse(output)
  output = nil #Allows that memory to be garbage collected
  GC.start #Force it to be garbage collected, to get that giant string(Hundreds of millions of chars) out of memory.
  puts "Length: #{x.length}"
  x = x.group_by do |row|
    repo = row["url"].match(/https:\/\/github.com\/(.*)/)[1]
    if m
      ts = Date.parse(row["timestamp"])
      [row["forks"].to_i,repo,ts.year.to_i,ts.month.to_i]
    else
      repo
    end
  end
  if m
    #faster to group by this after initially grouping by them all together
    #This prevents two group_by's on a very large set of data
    #This gets a list of all the months years, to fill in ones that are missing
    monthsyears = x.keys.group_by{|k| k[2..3]}.keys
    #This gets a list of all the repos
    repos = x.keys.group_by{|k| k[0..1]}.keys
    repos.each do |r|
      monthsyears.each do |my|
        x[r+my] ||= []
      end
    end
  end

  x = x.customsort(false,true,true,true) if m
  puts "Finished parsing in #{Time.now-clock}"
  puts "Writing to file"
  clock = Time.now
  filename = "event-stream-#{n}"
  filename += "-t" if t
  filename += "-l" if l
  filename += "-m" if m
  CSV.open("#{filename}.csv", 'w') do |csv|
    csv << x.collect do |k,v|
      k=k[1..-1].join("_") if m
      if t
        ["#{k}_events", "#{k}_timestamps"]
      else
        "#{k}_events"
      end
    end.flatten
    loop do
      b = x.collect do |k,v|
        a = v.shift
        if t
          if a.nil?
            [nil,nil]
          else
            [a["event"], a["timestamp"]]
          end
        else
          if a.nil?
            nil
          else
            a["event"]
          end
        end
      end.flatten
      break if b.compact.empty?
      csv << b
    end
  end
  puts "Finished writing in #{Time.now-clock}"
end

num = options[:n] || 100

update_top(num) if options[:u]
get_fork_stream(num) if options[:f]
get_event_stream(num, options[:m], options[:l], options[:t]) if options[:e]
GC.start
