# NOTICE: THIS PROJECT IS NO LONGER MAINTAINED
Please migrate to
[pod_feeder_v2](https://gitlab.com/brianodonnell/pod_feeder_v2) and let this
version die with dignity 🙂

# pod_feeder
Publishes RSS/Atom feeds to Diaspora*

This is a lightweight, customizable "bot" script to harvest RSS/Atom feeds and re-publish them to the Diaspora social network. It is posted here without warranty, for public use.

## Installation

 You must have the following perl modules installed:

- LWP::UserAgent
- URI::Escape
- HTML::Entities
- JSON
- XML::Simple
- DBD::SQLite
- HTML::FormatMarkdown

For instance, on a debian system you can install them like so:

`sudo apt-get install libwww-perl libany-uri-escape-perl libhtml-parser-perl libjson-perl libxml-simple-perl libdbd-sqlite3-perl libhtml-format-perl`

This script is intended to be run as a cron job, which might look something like this:

`@hourly  ~/pod_feeder.pl --feed-id myfeed --feed-url http://example.com/feeds/rss --pod-url https://diaspora.hzsogood.net --username user --password supersecretpassword --category-tags --title-tags > /dev/null 2>&1`

## Usage

    -a   --aspect-id <id>                Aspects to share with. May specify multiple times (default: 'public')
    -b   --embed-image                   Embed an image in the post if a link exists (default: off)
         --body                          Post the body of the feed (description or content:encoded item)
    -c   --category-tags                 Attempt to automatically hashtagify RSS item 'categories' (default: off)
    -d   --database <sqlite file>        The SQLite file to store feed data (default: 'feed.db')
    -e   --title-tags                    Automatically hashtagify RSS item title
    -f   --feed-url <http://...>         The feed URL
    -g   --user-agent <string>           Use this to spoof the user-agent if the feed blocks bots (ex: 'Mozilla/5.0')
    -i   --feed-id <string>              An arbitrary identifier to associate database entries with this feed
    -j   --no-branding                   Do not include 'posted via pod_feeder' footer to posts
    -l   --pod-url <https://...>         The pod URL
    -m   --timeout <hours>               How long (in hours) to keep attempting failed posts (default 72)
    -n   --ignore-tag <#hashtag>         Hashtags to filter out. May be specified multiple times (default: none)
    -o   --fetch-only                    Don't publish to Diaspora, just queue the new feed items for later
    -p   --password <********>           The D* user password
    -r   --url-tags                      Attempt to automatically hashtagify the RSS link URL (default: off)
    -t   --auto-tag <#hashtag>           Hashtags to add to all posts. May be specified multiple times (default: none)
    -s   --insecure                      Allows the option to bypass any errors caused from self-signed certificates(default: off)
    -u   --username <user>               The D* login username
    -v   --via <string>                  Sets the 'posted via' text (default: 'pod_feeder')
    -w   --post-raw-link                 Post the raw link instead of hyperlinking the article title (default: off)
    -x   --limit <n>                     Only post n items per script run, to prevent post-spamming (default: no limit)

## A Note on YouTube Feeds

It is possible to publish a YouTube channel's feed, by using the following URL format:

    https://www.youtube.com/feeds/videos.xml?channel_id=<channel id>
