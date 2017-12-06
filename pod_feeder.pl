#!/usr/bin/perl
# vim:set sw=8 ts=8 sts=8 ft=perl expandtab:

##
## pod_feeder.pl
##
## A script to auto-post RSS/Atom feeds to a Diaspora account
##
## created 20150416 by Brian Ó <brian@hzsogood.net>
## (on diaspora: brian@diaspora.hzsogood.net)
##
## I owe a great debt to the code of diaspora-rss-bot (https://github.com/spkdev/diaspora-rss-bot)
## for helping me understand how play nice with CSRF tokens et al
##

use strict;
use warnings;
use utf8;
use LWP::UserAgent;
use URI::Escape;
use HTML::Entities;
use JSON;
use XML::Simple;
use DBI;
use Unicode::Normalize 'normalize';
use Getopt::Long;
use HTML::FormatMarkdown;

my $opts = {
        'database' => './pod_feeder.db',
        'limit'    => 0,
        'timeout'  => 72,  # hours
        'via'      => 'pod_feeder',
};
my @auto_tags = ();
my @ignored_tags = ();
my @aspect_ids = ();

GetOptions(
        $opts,
        'aspect-id|a=s'     => \@aspect_ids,
        'auto-tag|t=s'      => \@auto_tags,
        'body',
        'category-tags|c',
        'database|d=s',
        'embed-image|b',
        'feed-id|i=s',
        'feed-url|f=s',
        'fetch-only|o',
        'help|h',           => \&usage,
        'ignore-tag|n=s',   => \@ignored_tags,
        'insecure|s=s',
        'limit|x=i',
        'no-branding',
        'password|p=s',
        'pod-url|l=s',
        'post-raw-links|w',
        'timeout|m=i',
        'title-tags|e',
        'url-tags|r',
        'user-agent|g=s',
        'username|u=s',
        'via|v=s',
);

# defaults to 'public' if no aspect ids are specified
$aspect_ids[@aspect_ids] = 'public' unless @aspect_ids;

# some feeds block bots, so you can spoof the user agent string with something such as 'Mozilla/5.0' to get around this
my $user_agent = $opts->{'user-agent'} || undef;

# initialize the database if it does not exist
eval { init_database( $opts->{'database'} ) };
die "ERROR: Coult not initialize the database: $@" if $@;

# fetch the feed
my ( $fetched, $feed ) = fetch_feed( $opts->{'feed-url'}, $user_agent );

if( $fetched ){
        eval {
                # update the database
                update_feed(
                        $feed,
                        db_file                 => $opts->{'database'},
                        feed_id                 => $opts->{'feed-id'},
                        auto_tags               => hashtagify( \@auto_tags ),
                        ignored_tags            => hashtagify( \@ignored_tags ),
                        extract_tags_from_url   => $opts->{'url-tags'},
                        extract_tags_from_title => $opts->{'title-tags'},
                        tag_categories          => $opts->{'category-tags'},
                );
        };
        warn "$@" if $@;

        eval {
                # publish new feed items to the pod, unless the user specified --fetch-only
                publish_feed_items(
                        db_file     => $opts->{'database'},
                        embed_image => $opts->{'embed-image'},
                        feed_id     => $opts->{'feed-id'},
                        timeout     => $opts->{'timeout'},
                        pod_url     => $opts->{'pod-url'},
                        username    => $opts->{'username'},
                        password    => $opts->{'password'},
                        aspect_ids  => \@aspect_ids,
                        raw_link    => $opts->{'post-raw-links'},
                        limit       => $opts->{'limit'},
                        no_branding => $opts->{'no-branding'},
                        via         => $opts->{'via'},
                        insecure    => $opts->{'insecure'},
                        body        => $opts->{'body'}
                ) unless $opts->{'fetch-only'};
        };
        warn "$@" if $@;
}
else {
        die "Error fetching $opts->{'feed-url'} : " . $feed->code . ' ' . $feed->message;
}

# publishes un-posted items in the database
sub publish_feed_items {
        my ( %params ) = @_;
        my @updates = ();
        my $query_string = "SELECT guid, title, link, image, image_title, hashtags, body FROM feeds WHERE feed_id == ? AND posted == 0 AND timestamp > ? ORDER BY timestamp";
        my $dbh = connect_to_db( $params{'db_file'} );

        # limit the number of items published if limit is specified
        $query_string .= " LIMIT $params{'limit'}" if $params{'limit'} > 0;

        my $sth = $dbh->prepare( $query_string ) or die "Can't prepare statement: $DBI::errstr";

        $sth->execute( $params{'feed_id'}, time - ( $params{'timeout'} * 3600 ) ) or die "Can't execute statement: $DBI::errstr";

        while( my $row = $sth->fetchrow_hashref() ){
                push( @updates, $row );
        }

        foreach my $update ( @updates ){
                my $content = $update->{'hashtags'};

                if( $params{'embed_image'} and length $update->{'image'} ){
                    my $image_link = '[![](' . $update->{'image'};
                    $image_link .= ' "' . $update->{'image_title'} . '"' if length $update->{'image_title'};
                    $image_link .= ')](' . $update->{'link'} . ')';
                    $content = "$image_link\n$content";
                }

                # to hyperlink the title or not to hyperlink the title...
                if( $params{'raw_link'} ){
                        $content = '### ' . $update->{'title'} . "\n\n" . $update->{'link'} . "\n" . $content;
                }
                else {
                        $content = '### [' . $update->{'title'} . '](' . $update->{'link'} . ")\n\n" . $content;
                }

                $content .= "\n" . $update->{'body'} if $params{'body'};

                print "Publishing $params{'feed_id'}\t$update->{'guid'}\n";
                my $post = publish_post( $content, %params );

                # mark the item as successfully posted
                if( $post->is_success ){
                        $sth = $dbh->prepare( "UPDATE feeds SET posted = 1 WHERE guid = ?" ) or die "Can't prepare statement: $DBI::errstr";
                        $sth->execute( $update->{'guid'} ) or die "Can't execute statement: $DBI::errstr";
                }
                else {
                        warn $post->code . ' ' . $post->message;
                }

                # Now, don't be hasty, master Meriadoc
                sleep 1;
        }

        $dbh->disconnect();
}

# adds new feed items to the database
sub update_feed {
        my ( $feed, %params ) = @_;

        $params{'auto_tags'} = [] unless defined $params{'auto_tags'};
        $params{'extract_tags_from_url'} = 0 unless defined $params{'extract_tags_from_url'};
        $params{'tag_categories'} = 0 unless defined $params{'tag_categories'};
        $params{'ignored_tags'} = [] unless defined $params{'ignored_tags'};

        my $items = get_feed_items( $feed, %params );
        my $dbh = connect_to_db( $params{'db_file'} );

        foreach my $item ( @$items ){
                # strip junk
                map { $item->{$_} =~ s/^\s+|\s+$//g } keys %$item;
                map { $item->{$_} =~ s/^\n+|\n+$//g } keys %$item;

                # decode uft8 strings before storing in the db
                map { utf8::decode($item->{'title'}) } keys %$item;
                map { utf8::decode($item->{'body'}) } keys %$item;

                # check to see if it exists already
                my $sth = $dbh->prepare("SELECT guid FROM feeds WHERE guid == ? LIMIT 1") or die "Can't prepare statement: $DBI::errstr";
                $sth->execute( $item->{'guid'} ) or die "Can't execute statement: $DBI::errstr";
                my $row = $sth->fetch();

                # and if not, insert it
                unless( defined $row ){
                        $sth = $dbh->prepare(
                                "INSERT INTO feeds( guid, feed_id, title, body, link, image, image_title, hashtags, posted, timestamp ) VALUES( ?, ?, ?, ?, ?, ?, ?, ?, ?, ? )"
                        ) or die "Can't prepare statement: $DBI::errstr";
                        $sth->execute(
                                $item->{'guid'},
                                $params{'feed_id'},
                                $item->{'title'},
                                $item->{'body'},
                                $item->{'link'},
                                $item->{'image'},
                                $item->{'image_title'},
                                join( ' ', @{$item->{'hashtags'}} ),
                                0,
                                time,
                        ) or die "Can't execute statement: $DBI::errstr";
                }
        }

        $dbh->disconnect();
}

sub connect_to_db {
        my ( $db_file ) = @_;
        my $dbh = DBI->connect("dbi:SQLite:dbname=$db_file", '', '', { RaiseError => 1, sqlite_unicode => 0 } ) or die $DBI::errstr;

        return $dbh;
}

# parse the individual items from the feed
sub get_feed_items {
        my ( $feed, %params ) = @_;
        my @items = ();
        my $list = decode_feed( $feed );

        $params{'auto_tags'} = [] unless defined $params{'auto_tags'};
        $params{'extract_tags_from_url'} = 0 unless defined $params{'extract_tags_from_url'};
        $params{'tag_categories'} = 0 unless defined $params{'tag_categories'};
        $params{'ignored_tags'} = [] unless defined $params{'ignored_tags'};

        foreach my $item ( @$list ){
                my $link = $item->{'link'};

                # no link, no go
                next unless defined $link and ref $link ne 'HASH' and ref $link ne 'ARRAY';

                my @hashtags = ();
                my $guid = undef;
                my $image = '';
                my $image_title = '';

                # strip trailing /
                $link =~ s/\/+$// if defined $link;

                # add user-specified tags
                push( @hashtags, @{$params{'auto_tags'}} ) if defined $params{'auto_tags'};

                # try to guess tags from the url
                if( $params{'extract_tags_from_url'} ){
                        # grab last part of url
                        $link =~ m/\/([^\/]+)$/;
                        my $link_part = $1;

                        # strip off any url params
                        $link_part =~ s/(\?.*)$//;

                        # split up string
                        my @parts = split( /([^[[:alnum:]]]|[[:blank:]]|[[:punct:]])/, $link_part );

                        push( @hashtags, @parts );
                }

                # try to guess tags from the title
                if( $params{'extract_tags_from_title'} ){
                        my $title = $item->{'title'};

                        # strip apostrophes
                        $title =~ s/('|`)//g;

                        # split up string on non-alphanumerics
                        my @parts = split( /([^[[:alnum:]]]|[[:blank:]]|[[:punct:]])/, $title );
                        my @tags = ();

                        foreach my $part ( @parts ){
                                push( @tags, $part ) unless $part =~ m/^(\s+)?$/;
                        }

                        push( @hashtags, @tags );
                }

                # try to extract tags from the feed categories (if they exist)
                if( $params{'tag_categories'} and defined $item->{'category'} ){
                        my @categories = ();

                        if( ref $item->{'category'} ne 'ARRAY' ){
                                @categories = ( $item->{'category'} );
                        }
                        else {
                                @categories = @{$item->{'category'}};
                        }

                        push ( @hashtags, @categories );
                }

                # extract image link and hover text from content:encoded if it exists
                if( defined $item->{'content:encoded'} ){
                        $item->{'content:encoded'} =~ /img .* ?src=\\?'(https?:\/\/[^']+)/ unless $item->{'content:encoded'} =~ /img .* ?src=\\?"(https?:\/\/[^"]+)/;

                        if( defined $1 ){
                                $image = $1;
                                $item->{'content:encoded'} =~ / title='([^']+)/ unless $item->{'content:encoded'} =~ / title="([^"]+)/;
                                $image_title = $1 if defined $1;
                        }
                }

                # extract image link and hover text from description if it exists
                if( not length $image and defined $item->{'description'} ){
                        $item->{'description'} =~ /img .* ?src='(https?:\/\/[^']+)/ unless $item->{'description'} =~ /img .* ?src="(https?:\/\/[^"]+)/;

                        if( defined $1 ){
                                $image = $1;
                                $item->{'description'} =~ / title='([^']+)/ unless $item->{'description'} =~ / title="([^"]+)/;
                                $image_title = $1 if defined $1;
                        }
                }

                # extract the image link from the enclosure tag if it exists
                if( not length $image and defined $item->{'enclosure'} and defined $item->{'enclosure'}->{'type'} and $item->{'enclosure'}->{'type'} =~ /^image\// ){
                        $image = $item->{'enclosure'}->{'url'} if defined $item->{'enclosure'}->{'url'};
                }

                # remove any query params from image link
                $image =~ s/(\?.*)$//;

                @hashtags = sort @hashtags;

                if( defined $item->{'guid'} ){
                        if( ref $item->{'guid'} eq 'HASH' and defined $item->{'guid'}->{'content'} ){
                                $guid = $item->{'guid'}->{'content'};
                        }
                        elsif( ref $item->{'guid'} ne 'HASH' ) {
                                $guid = $item->{'guid'};
                        }
                }
                elsif( defined $item->{'id'} ){
                        $guid = $item->{'id'};
                }
                else { $guid = $link }

                @hashtags = @{ hashtagify( \@hashtags ) };

                # filter out ignored tags
                for( my $t = 0; $t < @hashtags; $t++ ){
                        foreach my $ignored ( @{$params{'ignored_tags'}} ){
                                splice( @hashtags, $t, 1 ) if $hashtags[$t] eq $ignored;
                        }
                }

		my $body = '';
                $body    = HTML::FormatMarkdown->format_from_string($item->{'description'}, rm => 100000) if ($item->{'description'});
                $body    = HTML::FormatMarkdown->format_from_string($item->{'content:encoded'}, rm => 100000) if ($item->{'content:encoded'});

                my $obj = {
                        guid        => $guid,
                        title       => $item->{'title'},
                        body        => $body,
                        link        => $link,
                        image       => $image,
                        image_title => $image_title,
                        hashtags    => \@hashtags,
                };

                $items[@items] = $obj;
        }

        # the last shall be first and the first shall be last
        my @reversed = ();
        for( my $i = $#items; $i >= 0; $i-- ){
                $reversed[@reversed] = $items[$i];
        }

        return \@reversed;
}

# extract the data we need based on feed type (RSS v. Atom)
sub decode_feed{
        my ( $feed ) = @_;
        my @list = ();

        # RSS
        if( defined $feed->{'channel'} and defined $feed->{'channel'}->{'item'} ){
                if( ref $feed->{'channel'}->{'item'} eq 'ARRAY' ){
                        @list = @{$feed->{'channel'}->{'item'}};
                }
                elsif( ref $feed->{'channel'}->{'item'} eq 'HASH' ){
                        if( length( keys %{$feed->{'channel'}->{'item'}} ) == 1 ){
                                $list[@list] = $feed->{'channel'}->{'item'}
                        }
                        else{
                                @list = values %{$feed->{'channel'}->{'item'}};
                        }
                }
        }
        elsif( defined $feed->{'item'} ){
                if( ref $feed->{'item'} eq 'ARRAY' ){
                        @list = @{$feed->{'item'}};
                }
                elsif( ref $feed->{'item'} eq 'HASH' ){
                        @list = values %{$feed->{'item'}};
                }
        }
        # Atom
        elsif( defined $feed->{'entry'} and ref $feed->{'entry'} eq 'HASH' ){
                my $entries = $feed->{'entry'};

                foreach my $guid ( keys %$entries ){
                        my $item = {
                                guid    => $guid,
                        };

                        if( defined $entries->{$guid}->{'title'} ){
                                if( ref $entries->{$guid}->{'title'} eq 'HASH' and defined $entries->{$guid}->{'title'}->{'content'} ){
                                        $item->{'title'} = $entries->{$guid}->{'title'}->{'content'};
                                }
                                elsif( ref $entries->{$guid}->{'title'} eq '' ){
                                        $item->{'title'} = $entries->{$guid}->{'title'};
                                }
                        }

                        if( defined $entries->{$guid}->{'link'} ){
                                if( ref $entries->{$guid}->{'link'} eq 'HASH' and defined $entries->{$guid}->{'link'}->{'href'} ){
                                        $item->{'link'} = $entries->{$guid}->{'link'}->{'href'};
                                }
                                elsif( ref $entries->{$guid}->{'link'} eq '' ){
                                        $item->{'link'} = $entries->{$guid}->{'link'};
                                }
                        }

                        $item->{'category'} = $entries->{'category'} if defined $entries->{'category'};

                        if( defined $entries->{$guid}->{'summary'} ){
                                if( ref($entries->{$guid}->{'summary'}) eq 'HASH' and defined $entries->{$guid}->{'summary'}->{'content'} ){
                                        $item->{'description'} = $entries->{$guid}->{'summary'}->{'content'};
                                }
                                else {
                                        $item->{'description'} = $entries->{$guid}->{'summary'};
                                }
                        }

                        push( @list,  $item ) if defined $item->{'link'} and defined $item->{'title'};
                }
        }

        return \@list;
}

# fetch the feed and convert the XML to an data object
sub fetch_feed {
        my ( $feed_url, $user_agent_string ) = @_;
        my $ua = LWP::UserAgent->new();

        $ua->agent( $user_agent_string ) if defined $user_agent_string;

        my $response = $ua->get( $feed_url );

        if( $response->is_success ){
            my $dc = $response->decoded_content;
            if( Encode::is_utf8($dc) ){
                return ( 1, XMLin normalize( 'D', $response->decoded_content ) );
            }
            else {
                return ( 1, XMLin $dc );
            }
        }
        else {
                return ( 0, $response );
        }
}

# sanitize and de-dupe tags
sub hashtagify {
        my ( $list_ref ) = @_;
        my %hashtags = ();
        my @list = @$list_ref;

        foreach my $item ( @list ){
                # remove non-alphanumerics
                $item =~ s/[^[[:alnum:]]]//g;

                # drop stop words
                # TODO : make these overridable
                next if length( $item ) < 3;
                next if lc( $item ) =~ m/^(a(lso|nd|ny|re)|been|but|can(not|t)?|e(ach|tc|very)|for|from|g(e|o)t|ha(d|ve)|has(nt)?|hers?|hi(m|s)|how|its|no(r|t)|ours?|she|some|th(an|at|em?|eirs?|(e|o)se|ey|eyre|is)|too|very|was|wh(at|en|o)|with|you(r|rs)?)$/;
                # hashtagify it
                $item = '#' . $item unless $item =~ m/^#/;

                # use a hash here instead of an ordered list for auto-dedupe
                $hashtags{ lc( $item ) } = undef;
        }

        my @deduped = keys %hashtags;
        my @sorted = sort @deduped;

        return \@sorted;
}

# publish a post to the pod
sub publish_post {
        my ( $content, %params ) = @_;
        my $posted = 0;

        # create our user agent
        my $ua = LWP::UserAgent->new( requests_redirectable => [ 'GET', 'HEAD', 'POST' ] );

        # initialize an empty cookie jar
        $ua->cookie_jar( {} );

        # allow option for insecure certs
        if( $params{'insecure'} ){
                $ua->ssl_opts( verify_hostname  => 0);
        }

        # log in
        my $login_response = login( $ua, $params{'pod_url'}, $params{'username'}, $params{'password'} ) ;

        # if we've logged in successfully, post the message
        if( $login_response->is_success ){
                # # encode utf-8 characters
                # utf8::encode($content);

                my $post = post_message( $ua, $params{'pod_url'}, $content, $params{'aspect_ids'}, %params );
                #logout( $ua, $pod_url );
                return $post;
        }
        else {
                return $login_response;
        }
}

# log in to the pod
sub login {
        my ( $ua, $base_url, $username, $password ) = @_;
        my $sign_in_url = "$base_url/users/sign_in";

        $ua->cookie_jar->clear();

        my ( $sign_in, $result ) = get_page( $ua, $sign_in_url );

        if( $sign_in ){
                my $csrf = extract_token( $result );
                my $urlencoded_params = '';
                my $params = {
                        $csrf->{'param'}        => $csrf->{'token'},
                        'utf8'                  => '%E2%9C%93',
                        'user[username]'        => $username,
                        'user[password]'        => $password,
                        'user[remember_me]'     => 1,
                        'commit'                => 'Sign in'
                };

                foreach my $key ( keys %$params ){
                        $urlencoded_params .= uri_escape( $key ) . '=' . uri_escape( $params->{$key} ) . '&';
                }

                return $ua->post( $sign_in_url, 'Content' => $urlencoded_params, 'Content-Type' => 'application/x-www-form-urlencoded' );
        }
        else {
                return $result;
        }
}

# retreive a web page via GET
sub get_page {
        my ( $ua, $url ) = @_;
        my $response = $ua->get( $url );

        if( $response->is_success ){
                return ( 1, $response->decoded_content );
        }
        else {
                return ( 0, $response );
        }
}

# extract the CSRF token from the page's source code
sub extract_token {
        my ( $html ) = @_;
        my $csrf = {};

        # parse out CSRF param and token
#        $html =~ m/meta content="([^"]+)" name="csrf-param"/;
        $html =~ m/meta name="csrf-param" content="([^"]+)"/;
        $csrf->{'param'} = decode_entities( $1 ) if defined ( $1 );
#        $html =~ m/meta content="([^"]+)" name="csrf-token"/;
        $html =~ m/meta name="csrf-token" content="([^"]+)"/;
        $csrf->{'token'} = decode_entities( $1 ) if defined ( $1 );

        return $csrf if defined $csrf->{'param'} and defined $csrf->{'token'};
}

# make any necessary string manipulations to play nice with markdown
sub format_content {
        my ( $content, %params ) = @_;

        $content =~ s/\n/\n\n/g;
        $content .= "\nposted by [pod_feeder](https://github.com/rev138/pod_feeder)" unless( $params{'no_branding'} );

        return $content;
}

# post a message
sub post_message {
        my ( $ua, $base_url, $content, $aspect_ids, %params ) = @_;
        my ( $get_stream, $result ) = get_page( $ua, "$base_url/stream" );

        if( $get_stream ){
                my $csrf = extract_token( $result );
                my $post_url = "$base_url/status_messages";
                my $message = { status_message => { text => format_content( $content, %params ),  provider_display_name => $params{'via'} }, aspect_ids => $aspect_ids };
                my $json = JSON->new->allow_nonref;

                # $json = $json->utf8(1) unless utf8::is_utf8( $message );

                my $json_message = $json->encode( $message );


                return $ua->post( $post_url, 'Content' => $json_message, 'Content-Type' => 'application/json; charset=UTF-8', 'X-CSRF-Token' => $csrf->{'token'}  );
        }

}

# create a new sqlite db file with a 'feeds' table if it does not exist already
sub init_database {
        my ( $db_file ) = @_;

        unless( -e $db_file ){
	        my $dbh = connect_to_db( $db_file );
                my $sth = $dbh->prepare(
                        'CREATE TABLE feeds(guid VARCHAR(255) PRIMARY KEY,feed_id VARCHAR(127),title VARCHAR(255),link VARCHAR(255),image VARCHAR(255),image_title VARCHAR(255),hashtags VARCHAR(255),timestamp INTEGER(10),posted INTEGER(1),body VARCHAR(10000))'
                ) or die "Can't prepare statement: $DBI::errstr";

                $sth->execute() or die "Can't execute statement: $DBI::errstr";
                $dbh->disconnect();
        }
        else {
                my $dbh = connect_to_db( $db_file );
	        my $sth = $dbh->column_info(undef, undef, 'feeds', undef);
                my $body_exists = 0;
                while( my( $tcat, $tscheme, $tname, $column_name ) = $sth->fetchrow_array() ) {
                        $body_exists = 1 if $column_name eq 'body';
                }
                unless( $body_exists ) {
                        $sth = $dbh->prepare('ALTER TABLE feeds ADD body VARCHAR(10000)');
                        $sth->execute() or die "Can't execute statement: $DBI::errstr";
                }
                $dbh->disconnect();
        }
}

sub usage {
        print "$0\n";
        print "usage:\n";
        print "    -a   --aspect-id <id>                Aspects to share with. May specify multiple times (default: 'public')\n";
        print "    -b   --embed-image                   Embed an image in the post if a link exists (default: off)\n";
        print "    -c   --category-tags                 Attempt to automatically hashtagify RSS item 'categories' (default: off)\n";
        print "    -d   --database <sqlite file>        The SQLite file to store feed data (default: 'feed.db')\n";
        print "    -e   --title-tags                   Automatically hashtagify RSS item title\n";
        print "    -f   --feed-url <http://...>         The feed URL\n";
        print "    -g   --user-agent <string>           Use this to spoof the user-agent if the feed blocks bots (ex: 'Mozilla/5.0')\n";
        print "    -i   --feed-id <string>              An arbitrary identifier to associate database entries with this feed\n";
        print "    -j   --no-branding                   Do not include 'posted via pod_feeder' footer to posts\n";
        print "    -l   --pod-url <https://...>         The pod URL\n";
        print "    -m   --timeout <hours>               How long (in hours) to keep attempting failed posts (default 72)\n";
        print "    -n   --ignore-tag <#hashtag>         Hashtags to filter out. May be specified multiple times (default: none)\n";
        print "    -o   --fetch-only                    Don't publish to Diaspora, just queue the new feed items for later\n";
        print "    -p   --password <********>           The D* user password\n";
        print "    -r   --url-tags                      Attempt to automatically hashtagify the RSS link URL (default: off)\n";
        print "    -t   --auto-tag <#hashtag>           Hashtags to add to all posts. May be specified multiple times (default: none)\n";
        print "    -s   --insecure                      Allows the option to bypass any errors caused from self-signed certificates(default: off)\n";
        print "    -u   --username <user>               The D* login username\n";
        print "    -v   --via <string>                  Sets the 'posted via' text (default: 'pod_feeder')\n";
        print "    -w   --post-raw-link                 Post the raw link instead of hyperlinking the article title (default: off)\n";
        print "    -x   --limit <n>                     Only post n items per script run, to prevent post-spamming (default: no limit)\n";
        print "         --body                          Post the body of the feed (description or content:encoded item)\n";
        print "\n";

        exit;
}
