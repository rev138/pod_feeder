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
- Unicode::Normalize
- Getopt::Long

This script is intended to be run as a cron job, which might look something like this:

`@hourly  ~/pod_feeder.pl --feed-id myfeed --feed-url http://example.com/feeds/rss --pod-url https://diaspora.hzsogood.net --username user --password supersecretpassword --category-tags --title-tags > /dev/null 2>&1`

## Usage

    -a   --aspect-id <id>                Aspects to share with. May specify multiple times (default: 'public')
    -c   --category-tags                 Attempt to automatically hashtagify RSS item 'categories' (default: off)
    -d   --database <sqlite file>        The SQLite file to store feed data (default: 'feed.db')
    -e   --title-tags                    Automatically hashtagify RSS item title
    -f   --feed-url <http://...>         The feed URL
    -g   --user-agent <string>           Use this to spoof the user-agent if the feed blocks bots (ex: 'Mozilla/5.0')
    -i   --feed-id <string>              An arbitrary identifier to associate database entries with this feed
    -l   --pod-url <https://...>         The pod URL
    -m   --timeout <hours>               How long (in hours) to keep attempting failed posts (default 72)
    -o   --fetch-only                    Don't publish to Diaspora, just queue the new feed items for later
    -p   --password <********>           The D* user password
    -r   --url-tags                      Attempt to automatically hashtagify the RSS link URL (default: off)
    -t   --auto-tag <#hashtag>           Hashtags to add to all posts. May be specified multiple times (default: none)
    -u   --username <user>               The D* login username
    -w   --post-raw-link                 Post the raw link instead of hyperlinking the article title (default: off)

## A Note on YouTube Feeds

It is possible to publish a YouTube channel's feed, however YT makes it a little difficult:

Get the URL of the YouTube Channel, ex:

https://www.youtube.com/channel/UCQzdMyuz0Lf4zo4uGcEujFw

Modify it thusly, then feed it to the script:

[https://www.youtube.com/**rss**/channel/UCQzdMyuz0Lf4zo4uGcEujFw/**feed.rss**](https://www.youtube.com/rss/channel/UCQzdMyuz0Lf4zo4uGcEujFw/feed.rss)

If you'd want Diaspora to automatically embed the video, you must also pass the `--post-raw-link` argument
