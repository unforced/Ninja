# Github Ninja Data Aggregator - Specifications

### External Links

All output files generated are hosted [on dropbox](https://www.dropbox.com/sh/8vg37wmfh68gbyv/GmnQ7xH0vu).

A web interface for viewing the time series graphs of repository graphs can be
seen in my [Ninja-viewer repository](https://github.com/Aaronneyer/Ninja-viewer)

### Objectives

To produce a tool that queries githubarchive.org and the Github API, and
generates longitudinal social network data and other time series for
specified Github repositories. It will use a command line interface to
execute queries.

### Tools

1.  Ruby - [1.9+](http://ruby-doc.org/) - the programming language used
    to develop the tool
2.  BigQuery - [BigQuery](https://bigquery.cloud.google.com/) allows us
    to query all of the information stored by githubarchive.org. The bq
    command line tool is used for querying.
3.  Github API - The Github [API](http://developer.github.com/) allows
    us to retrieve who made commits as extended commit data is not
    available on BigQuery/githubarchive.org.
4.  igraph - Uses the [igraph
    gem](https://github.com/alexgutteridge/igraph). This requires the
    igraph C library. Newest version doesn’t work, use
    [0.5.4](http://sourceforge.net/projects/igraph/files/C%20library/0.5.4/) and
    use this command: gem install igraph --
    --with-igraph-include=/usr/local/include/igraph
    --with-igraph-lib=/usr/local/lib

### Output Format

The output needs to be read by the R packages igraph and RSiena. The
most complete format that these two use in common is
[GraphML](http://graphml.graphdrawing.org/), which the igraph ruby gem
can output to. When the snapshots are output, they will be output one
snapshot per file. For example, scanning the last 12 months of rubinius
will output rubinius\_rubinius\_0...rubinius\_rubinius\_12. This is the
format recommended for RSiena.

### Context to Query

The aggregator queries three main contexts:

1.  Commits
2.  Pull Requests
3.  Issues

Edges are formed between developers using their interactions within
these contexts. The following are the edges created:

1.  Commenting on a commit - Committer -- Commenter
2.  Commenting on a pull request - Pull Submitter -- Commenter
3.  Closing a  pull request - Pull Submitter -- Closer
4.  Closing an issue - Issue Submitter -- Closer
5.  Commenting on an issue - Issue Submitter -- Commenter

### Data Sources

We will utilize the following data sources:

1.  Github API
2.  Githubarchive.org data on BigQuery

BigQuery will be the primary data source, and most data will be pulled
from there. The Github API will be used to retrieve information on
commits, primarily, the user who made the commit, as commit data is not
available on githubarchive.org.

### Current Draft

For simplicity, the initial draft will use an undirected graph and all
edges will be considered the same, without differentiating based on
event. If there are multiple connections between nodes, the weight of
the edge will just increase for each connection.

The initial draft will also only have developers as nodes of the graph.
If necessary, this can be changed for a later stage, allowing artifacts
such as files, pull requests, issues, and commits to be considered
nodes, at which point there will also be edges created for developers
submitting any of said artifacts.

### Querying

For BigQuery, to save time and money on data processed, we will first
pull the top 100 repositories (number can vary). From there we pull only
the columns we need, on just the top 100 repositories, and store that
dataset in BigQuery. This dataset is only 140MB which dramatically
reduces costs, as it is $0.12 per GB of storage per month and $0.035
per GB processed with queries. Updating the dataset processes ~16GB of
data.

### BigQuery Data

When we query the bigquery data, we want to limit our requests to
specific events, and we only need information on certain fields:

| Field | Description | Used For |
| ----- | ----------- | -------- |
| actor | The user involved in this event | Gives the name of a node |
| payload\_action | Specifies what action was performed during this event | Used to identify opened/closed on issues and pull requests |
| type | What the github event was | Differentiates types of events so we can handle them differently |
| payload\_commit | sha of commit for this comment | Used with GithubAPI to retrieve the commit for this comment |
| payload\_number | The number that identifies this PR or Issue | Used to match opened/closed PR’s and Issues |
| url | The URL for this event | Used for retrieving the payload\_number for pull request comments, which don’t have it listed |
| repository\_name | Name of repository | Necessary because we retrieve information on repositories one at a time |
| repository\_owner | Owner of repository | Ditto above |

Processing each event:

Below I will outline the steps necessary for processing each event.

CommitCommentEvent:

Go through all of them, and collect all the commit
sha’s(payload\_commit). Make a unique list of these, then grab them all
using the github\_api gem, and group them by their sha(This step
prevents us from grabbing the same commit multiple time).

Now go through all of them again, and for each one, make an edge between
the “actor” and the commit owner(Which we retrieved from the API)

IssueEvent & PullRequestEvent:

Group them by opened/closed. For every closed one, generate an edge
between the actor of it, and the actor of the event with ‘opened’ with
the equivalent payload\_number.

IssueCommentEvent:

For each one, generate an edge between the “actor” and the issue/PR
owner(A hashmap of these is generated from the above step, use the
“actor” for the open ones).

PullRequestReviewCommentEvent:

Pull the PR number out of the url.  Use info we already got from
PullRequestEvent to get the “open” event with that PR number. Generate
an edge between the two actors.

### Plan of priorities

1.  Derive a graph for the rubinius/rubinius repository since as far
    back as you can go. Only need to measure “strength of interactions”
    as a summary measure. One snapshot per month. DONE
2.  Be able to find the 100/250/500 largest repositories per forks at
    any given point in time, and then derive “strength of interactions”
    graphs for each of those repos at monthly snapshots. DONE
3.  Extract event streams with timestamps for the 100/250/500 repos
    selected in bullet 2. DONE
4.  Extract time series of forks, total community members, “pull
    requesters”, and committers monthly for all the repositories
    selected in bullet 2
5.  Add extra detail to edges - separate edges for measuring the
    strength of commits, pull request, and issues-based edges - but also
    needs to have a summary measures
6.  Extract directed/non-directed networks
7.  Implement all the flags below
8.  Implement artifacts as nodes (creating artifact-actor networks)

### Flags

The scraper needs to be able to take the following flags:

1.  Static/dynamic network - on/off switch for whether a single network
    should be generated, or several snapshots over time
2.  Repositories to query (e.g. rubinius/rubinius)
3.  Time period to query (e.g. 2011-2012)
4.  Time unit for snapshots (days, months, quarters, half-years, or
    years)
5.  Level of granularity of relationships (either 1 relationship per
    context, or reduced to “interaction”, i.e. a single relationship for
    all interactions regardless of context)
6.  Directed or non-directed graph (i.e, either relationships are
    non-directed, as in “we are working on the same bug”, or they are
    directed as in “A commented on B’s commit” or “A merged B’s pull
    request)
7.  Strength of relationship on/off switch - either all relationships of
    the same type are equally valued, or they are evaluated by strength.
    I.e., if A and B interact frequently, their relationship will be
    strong (e.g. +1 for each interaction).
8.  Nodes - determines what counts as a node: artifacts, developers, or
    artifacts/developers
