#!/usr/bin/perl

##
## pod_tweeter.pl
##
## A script to auto-post Twitter feeds to a Diaspora account
##
## created 20150416 by Brian Ó <brian@hzsogood.net>
## (on diaspora: brian@diaspora.hzsogood.net)
## https://github.com/rev138/pod_feeder
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
use DBI;
use Unicode::Normalize 'normalize';
use Getopt::Long;
use Net::Twitter::Lite::WithAPIv1_1;
use DateTime;

my $opts = {
        'database'              => './pod_tweeter.db',
        'limit'			=> 0,
        'timeout'               => 72,  # hours
};
my @auto_tags = ();
my @aspect_ids = ();

GetOptions(
        $opts,
	'access-token|k=s',
	'access-token-secret|e=s',
        'aspect-id|a=s'         => \@aspect_ids,
        'auto-tag|t=s'          => \@auto_tags,
	'consumer-key|c=s',
	'consumer-secret|r=s',
        'database|d=s',
        'timeline-id|i=s',
        'fetch-only|o',
        'help|h',               => \&usage,
        'limit|x=i',
        'password|p=s',
        'pod-url|l=s',
	'screen-name|s=s',
        'timeout|m=i',
        'username|u=s',
);

# defaults to 'public' if no aspect ids are specified
$aspect_ids[@aspect_ids] = 'public' unless @aspect_ids;

# initialize the database if it does not exist
eval { init_database( $opts->{'database'} ) };
die "ERROR: Coult not initialize the database: $@" if $@;

eval {
	my $last_id = get_last_id( $opts->{'database'} );
	my %params = (
		access_token		=> $opts->{'access-token'},
		access_token_secret	=> $opts->{'access-token-secret'},
		consumer_key		=> $opts->{'consumer-key'},
		consumer_secret		=> $opts->{'consumer-secret'},
	);

	# limit the search to tweets since the last fetched, if we've fetched any
	$params{'since_id'} = $last_id if defined $last_id;
	# limit the results to the 10 most recent if we haven't fetched any yet
	$params{'count'} = 10 unless defined $last_id;
	# get the specified user's tweets
	$params{'screen_name'} = $opts->{'screen-name'} if defined $opts->{'screen-name'};

	# get the tweets
	my $tweets = get_tweets( %params );

	# update the database
        update_tweets(
		$tweets,
		db_file 		=> $opts->{'database'},
		timeline_id 		=> $opts->{'timeline-id'},
		auto_tags		=> hashtagify( \@auto_tags ),
	);
};
warn "$@" if $@;

eval {
	# publish new feed items to the pod, unless the user specified --fetch-only
	publish_feed_items(
		db_file		=> $opts->{'database'},
		timeline_id	=> $opts->{'timeline-id'},
		timeout		=> $opts->{'timeout'},
		pod_url		=> $opts->{'pod-url'},
		username	=> $opts->{'username'},
		password	=> $opts->{'password'},
		aspect_ids	=> \@aspect_ids,
		limit		=> $opts->{'limit'},
	) unless $opts->{'fetch-only'};
};
warn "$@" if $@;

# get the id of the most recently fetched tweet, if there is one in the DB
sub get_last_id {
	my ( $db_file ) = @_;
        my $query_string = "SELECT id FROM tweets ORDER BY timestamp DESC LIMIT 1";
        my $dbh = connect_to_db( $db_file );
        my $sth = $dbh->prepare( $query_string ) or die "Can't prepare statement: $DBI::errstr";

        $sth->execute() or die "Can't execute statement: $DBI::errstr";

	my $result = $sth->fetchrow_hashref;

	return $result->{'id'} if keys %$result || undef;
}

# get the most recent tweets, within limits
sub get_tweets {
	my ( %params ) = @_;
	my $query = { exclude_replies => 1 };

	my $twit = Net::Twitter::Lite::WithAPIv1_1->new(
		access_token		=> $params{'access_token'},
		access_token_secret	=> $params{'access_token_secret'},
		consumer_key		=> $params{'consumer_key'},
		consumer_secret		=> $params{'consumer_secret'},
		user_agent		=> 'pod_tweeter',
		ssl			=> 1,
	);
	my $tweets = undef;

	$query->{'since_id'} = $params{'since_id'} if defined $params{'since_id'};
	$query->{'count'} = $params{'count'} if defined $params{'count'};
	$query->{'screen_name'} = $params{'screen_name'} if defined $params{'screen_name'};

	eval {
		$tweets = $twit->user_timeline( $query );
	};

	if ( my $err = $@ ) {
		die $@ unless blessed $err && $err->isa('Net::Twitter::Lite::Error');

		warn	"HTTP Response Code: ", $err->code, "\n",
			"HTTP Message......: ", $err->message, "\n",
			"Twitter error.....: ", $err->error, "\n";
	}

	return $tweets;
}

# publishes un-posted items in the database
sub publish_feed_items {
        my ( %params ) = @_;
        my @updates = ();
	my $query_string = "SELECT id, timeline_id, text, link, hashtags, posted, timestamp FROM tweets WHERE timeline_id == ? AND posted == 0 AND timestamp > ? ORDER BY timestamp";
        my $dbh = connect_to_db( $params{'db_file'} );
        
        # limit the number of items published if limit is specified
        $query_string .= " LIMIT $params{'limit'}" if $params{'limit'} > 0;
        
        my $sth = $dbh->prepare( $query_string ) or die "Can't prepare statement: $DBI::errstr";

        $sth->execute( $params{'timeline_id'}, time - ( $params{'timeout'} * 3600 ) ) or die "Can't execute statement: $DBI::errstr";

        while( my $row = $sth->fetchrow_hashref() ){
                push( @updates, $row );
        }

        foreach my $update ( @updates ){
                my $content = '[](' . $update->{'link'} . ')' . $update->{'hashtags'};

                print "Publishing $params{'timeline_id'}\t$update->{'id'}\n";

                my $post = publish_post( $content, %params );

                # mark the item as successfully posted
                if( $post->is_success ){
                        $sth = $dbh->prepare( "UPDATE tweets SET posted = 1 WHERE id = ?" ) or die "Can't prepare statement: $DBI::errstr";
                        $sth->execute( $update->{'id'} ) or die "Can't execute statement: $DBI::errstr";
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
sub update_tweets {
        my ( $tweets, %params ) = @_;
        my $dbh = connect_to_db( $params{'db_file'} );

        foreach my $tweet ( @$tweets ){
                # check to see if it exists already
                my $sth = $dbh->prepare("SELECT id FROM tweets WHERE id == ? LIMIT 1") or die "Can't prepare statement: $DBI::errstr";
                $sth->execute( $tweet->{'id'} ) or die "Can't execute statement: $DBI::errstr";
                my $row = $sth->fetch();

                # and if not, insert it
                unless( defined $row ){
			# extract the hashtags from the tweet
			my @hashtags = ();
			foreach my $tag( @{$tweet->{'entities'}->{'hashtags'}} ){
				push ( @hashtags, $tag->{'text'} );
			}

			# add user-specified tags
	                push( @hashtags, @{$params{'auto_tags'}} ) if defined $params{'auto_tags'};

			# convert the created date to an epoch timestamp
			my $months = { Jan => 1, Feb => 2, Mar => 3, Apr => 4, May => 5, Jun => 6, Jul => 7, Aug => 8, Sep => 9, Oct => 10, Nov => 11, Dec => 12 }; 
			# example: 'created_at' => 'Sat Oct 04 00:47:10 +0000 2014',
			$tweet->{'created_at'} =~ m/^[A-Za-z]{3} ([A-Za-z]{3}) ([0-9]{2}) ([0-9]{2}):([0-9]{2}):([0-9]{2}) ([+-][0-9]{4}) ([0-9]{4})$/;
			my $dt = DateTime->new(
				month		=> $months->{$1},
				day		=> $2,
				hour		=> $3,
				minute		=> $4,
				second  	=> $5,
				time_zone	=> $6,
				year		=> $7,
			);
				
                        $sth = $dbh->prepare(
                                "INSERT INTO tweets( id, timeline_id, text, link, hashtags, posted, timestamp ) VALUES( ?, ?, ?, ?, ?, ?, ?)"
                        ) or die "Can't prepare statement: $DBI::errstr";
                        $sth->execute(
                        	$tweet->{'id'},
                        	$params{'timeline_id'},
                        	$tweet->{'text'},
                        	'https://twitter.com/' . $tweet->{'user'}->{'screen_name'} . '/status/' . $tweet->{'id'},
                        	join( ' ', @{hashtagify(\@hashtags)} ),
                        	0,
                        	$dt->epoch(),
                        ) or die "Can't execute statement: $DBI::errstr";
                }
        }

        $dbh->disconnect();
}

sub connect_to_db {
        my ( $db_file ) = @_;
        my $dbh = DBI->connect("dbi:SQLite:dbname=$db_file", '', '', { RaiseError => 1 } ) or die $DBI::errstr;

        return $dbh;
}

# sanitize and de-dupe tags
sub hashtagify {
        my ( $list_ref ) = @_;
        my %hashtags = ();
        my @list = @$list_ref;

        foreach my $item ( @list ){
                # remove non-alphanumerics
                $item =~ s/[^(\p{Letter}|\p{Number})]//g;

                # drop stop words
                next if length( $item ) < 3;
                next if lc( $item ) =~ m/^(and|are|but|for|from|how|its|the|this)$/;
                # hashtagify it
                $item = '#' . $item;
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

        # log in
        my $login_response = login( $ua, $params{'pod_url'}, $params{'username'}, $params{'password'} ) ;

        # if we've logged in successfully, post the message
        if( $login_response->is_success ){
                my $post = post_message( $ua, $params{'pod_url'}, $content, $params{'aspect_ids'} );
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
        $html =~ m/meta name="csrf-param" content="([^"]+)"/;
        $csrf->{'param'} = decode_entities( $1 ) if defined ( $1 );
        $html =~ m/meta name="csrf-token" content="([^"]+)"/;
        $csrf->{'token'} = decode_entities( $1 ) if defined ( $1 );

        return $csrf if defined $csrf->{'param'} and defined $csrf->{'token'};
}

# make any necessary string manipulations to play nice with markdown
sub format_content {
        my ( $content ) = @_;

        $content =~ s/\n/\n\n/g;
        $content .= "\nposted by [pod_tweeter](https://github.com/rev138/pod_feeder)";

        return $content;
}

# post a message
sub post_message {
        my ( $ua, $base_url, $content, $aspect_ids ) = @_;
        my ( $get_stream, $result ) = get_page( $ua, "$base_url/stream" );

        if( $get_stream ){
                my $csrf = extract_token( $result );
                my $post_url = "$base_url/status_messages";
                my $message = { status_message => { text => format_content( $content ),  provider_display_name => 'pod_tweeter' }, aspect_ids => $aspect_ids };
                my $json = JSON->new->allow_nonref;

                $json = $json->utf8(0) unless utf8::is_utf8( $message );

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
        		'CREATE TABLE tweets(id VARCHAR(20) PRIMARY KEY,timeline_id VARCHAR(127),text VARCHAR(140),link VARCHAR(255),hashtags VARCHAR(255),timestamp INTEGER(10),posted INTEGER(1))'
        	) or die "Can't prepare statement: $DBI::errstr";

        	$sth->execute() or die "Can't execute statement: $DBI::errstr";
        	$dbh->disconnect();
	}
}

sub usage {
        print "$0\n";
        print "usage:\n";
        print "    -a   --aspect-id <id>                Aspects to share with. May specify multiple times (default: 'public')\n";
	print "    -c   --consumer-key <string>         The twitter API consumer key\n";
        print "    -d   --database <sqlite file>        The SQLite file to store feed data (default: 'feed.db')\n";
	print "    -e   --access-token-secret <string>  The twitter API access token secret\n";
        print "    -i   --timeline-id <string>	         An arbitrary identifier to associate database entries with this feed\n";
	print "    -k   --access-token <string>         The twitter API access token\n";
        print "    -l   --pod-url <https://...>         The pod URL\n";
        print "    -m   --timeout <hours>               How long (in hours) to keep attempting failed posts (default: 72)\n";
        print "    -o   --fetch-only                    Don't publish to Diaspora, just queue the new feed items for later\n";
        print "    -p   --password <********>           The D* user password\n";
	print "    -r   --consumer-secret <string>      The twitter API consumer secret\n";
	print "    -s   --screen-name <\@screenname>     The twitter feed to scrape (default: the user associated with the API keys)\n";
        print "    -t   --auto-tag <#hashtag>           Hashtags to add to all posts. May be specified multiple times (default: none)\n";
        print "    -u   --username <user>               The D* login username\n";
        print "    -x	 --limit <n>			 Only post n items per script run, to prevent post-spamming (default: no limit)\n";
        print "\n";

        exit;
}
