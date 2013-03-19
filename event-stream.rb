#!/usr/bin/env ruby

require 'optparse'
require 'csv'

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
WHERE repository_name!='' AND repository_owner!=''
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
SELECT T.repository_url AS id, M.num_forks AS max_forks, MONTH(TIMESTAMP(T.created_at)) AS month,
YEAR(TIMESTAMP(T.created_at)) AS year, MIN(T.repository_forks) AS forks
FROM githubarchive:github.timeline AS T
JOIN mygithubarchives.top_#{n}_repos AS M ON T.repository_url=M.repository_url
GROUP BY id, max_forks, year, month
ORDER BY max_forks DESC, id ASC, year DESC, month DESC;
  EOF
  puts "Beginning fork_stream query"
  clock = Time.now
  csvoutput = `bq --format csv -q query --max_rows 99999999 "#{query}"`
  puts "Finished query in #{Time.now-clock}"
  puts "Parsing CSV"
  clock = Time.now
  x = CSV.parse(csvoutput)
  puts "Finished parsing in #{Time.now-clock}"
  puts "Writing to file"
  clock = Time.now
  CSV.open("fork-stream-#{n}.csv", 'w') do |csv|
    x.each_with_index do |a,i|
      if i==0
        csv << [a[0], "timestamp", a[4]]
      else
        csv << [a[0], Time.new(a[3],a[2]), a[4]]
      end
    end
  end
  puts "Finished writing in #{Time.now-clock}"
end


def get_event_stream(n)
  query = <<-EOF
SELECT T.repository_url AS id, M.num_forks AS forks, T.created_at AS timestamp, T.type AS event
FROM githubarchive:github.timeline AS T
JOIN mygithubarchives.top_#{n}_repos AS M ON T.repository_url=M.repository_url
ORDER BY forks DESC, id ASC, timestamp ASC;
  EOF
  puts "Beginning event_stream query"
  clock = Time.now
  csvoutput = `bq --format csv -q query --max_rows 99999999 "#{query}"`
  puts "Finished query in #{Time.now-clock}"
  puts "Parsing CSV"
  clock = Time.now
  x = CSV.parse(csvoutput)
  puts "Finished parsing in #{Time.now-clock}"
  puts "Writing to file"
  clock = Time.now
  CSV.open("event-stream-#{n}.csv", 'w') do |csv|
    x.each do |a|
      csv << (a[0..0]+a[2..-1])
    end
  end
  puts "Finished writing in #{Time.now-clock}"
end

num = options[:n] || 100
update_top(num) if options[:u]
get_fork_stream(num) if options[:f]
get_event_stream(num) if options[:e]
