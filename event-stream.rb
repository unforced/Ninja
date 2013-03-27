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
WHERE repository_name!='' AND repository_owner!='' AND MONTH(TIMESTAMP(created_at)) == 3 AND YEAR(TIMESTAMP(created_at)) == 2012
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


def get_event_stream(n,m=false)
  query = <<-EOF
SELECT T.repository_url AS url, M.num_forks AS forks, T.created_at AS timestamp, T.type AS event
FROM githubarchive:github.timeline AS T
JOIN mygithubarchives.top_#{n}_repos AS M ON T.repository_url=M.repository_url
ORDER BY forks DESC, url ASC, timestamp ASC;
  EOF
  puts "Beginning event_stream query"
  clock = Time.now
  output = `bq --format json -q query --max_rows 99999999 "#{query}"`
  puts "Finished query in #{Time.now-clock}"
  puts "Parsing JSON"
  clock = Time.now
  x = JSON.parse(output)
  output = nil #Allows that memory to be garbage collected
  GC.start #Force it to be garbage collected, to get that giant string(Hundreds of millions of chars) out of memory.
  puts "Finish first parse"
  puts "Length: #{x.length}"
  x = x.group_by do |row|
    repo = row["url"].match(/https:\/\/github.com\/(.*)/)[1]
    if m
      t = Date.parse(row["timestamp"])
      "#{repo}_#{t.year}_#{t.month}"
    else
      repo
    end
  end
  puts "Finished parsing in #{Time.now-clock}"
  puts "Writing to file"
  clock = Time.now
  CSV.open("event-stream-#{n}.csv", 'w') do |csv|
    csv << x.collect do |k,v|
      ["#{k}_events", "#{k}_timestamps"]
    end.flatten
    loop do
      b = x.collect do |k,v|
        a = v.shift
        if a.nil?
          [nil,nil]
        else
          [a["event"], a["timestamp"]]
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
get_event_stream(num, options[:m]) if options[:e]
GC.start
puts "It should really exit now"
