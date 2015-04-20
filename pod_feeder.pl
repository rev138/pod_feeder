#!/usr/bin/perl                          

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
## You can initialize the database thusly:                                                         
## $ echo "CREATE TABLE feeds( guid varchar(255) primary key, feed_id varchar(127), title varchar(255), link varchar(255), hashtags varchar(255), timestamp integer(10), posted integer(1) );" | sqlite3 feeds.db
##                                                                                                                                                                                           

use strict;
use warnings;
use LWP::UserAgent;
use URI::Escape;   
use HTML::Entities;
use JSON;          
use XML::Simple;   
use DBI;           
use Encode;        
use utf8;          
use Getopt::Long;  

my $opts = {
        'database'              => './feeds.db',
        'timeout'               => 72,  # hours
};                                             
my @auto_tags = ();                            
my @aspect_ids = ();                           

GetOptions(
        $opts,
        'aspect-id|a=s'         => \@aspect_ids,
        'auto-tag|t=s'          => \@auto_tags, 
        'category-tags|c',                      
        'database|d=s',                         
        'feed-id|i=s',                          
        'feed-url|f=s',                         
        'fetch-only|o',                         
        'help|h',               => \&usage,     
        'password|p=s',                         
        'pod-url|l=s',                          
        'timeout|m=i',                          
        'title-tags|e',
        'url-tags|r',                           
        'user-agent|g=s',                       
        'username|u=s',                         
);                                              

# make sure all tags start with '#'
foreach my $tag ( @auto_tags ){ $tag =~ s/^([^#])/#$1/ }

# defaults to 'public' if no aspect ids are specified
$aspect_ids[@aspect_ids] = 'public' unless @aspect_ids;

# some feeds block bots, so you can spoof the user agent string with something such as 'Mozilla/5.0' to get around this
my $user_agent = $opts->{'user-agent'} || undef;                                                                       

# fetch the feed
my ( $fetched, $feed ) = fetch_feed( $opts->{'feed-url'}, $user_agent );

if( $fetched ){
        eval { 
                # update the database
                update_feed( $opts->{'database'}, $feed, $opts->{'feed-id'}, \@auto_tags, $opts->{'url-tags'}, $opts->{'category-tags'}, $opts->{'title-tags'} );
        };                                                                                                                                
        warn "$@" if $@;                                                                                                                  

        eval {
                # publish new feed items to the pod, unless the user specified --fetch-only
                publish_feed( $opts->{'database'}, $opts->{'feed-id'}, $opts->{'timeout'}, $opts->{'pod-url'}, $opts->{'username'}, $opts->{'password'}, \@aspect_ids ) unless $opts->{'fetch-only'}; 
        };                                                                                                                                                                                            
        warn "$@" if $@;                                                                                                                                                                              
}                                                                                                                                                                                                     
else {                                                                                                                                                                                                
        die "Error fetching $opts->{'feed-url'} : " . $feed->code . ' ' . $feed->message;                                                                                                             
}                                                                                                                                                                                                     

# publishes un-posted items in the database
sub publish_feed {                         
        my ( $db_file, $feed_id, $timeout, $pod_url, $username, $password, $aspect_ids ) = @_;
        my @updates = ();                                                                     

        my $dbh = connect_to_db( $db_file );
        my $sth = $dbh->prepare(            
                "SELECT guid, title, link, hashtags FROM feeds WHERE feed_id == \"$feed_id\" AND posted == 0 AND timestamp > " . ( time - ( $timeout * 3600 ))
        ) or die "Can't prepare statement: $DBI::errstr";                                                                                              

        $sth->execute() or die "Can't execute statement: $DBI::errstr";

        while( my $row = $sth->fetchrow_hashref() ){
                push( @updates, $row );             
        }                                           

        foreach my $update ( @updates ){
                my $content = '[' . $update->{'title'} . '](' . $update->{'link'} . ")\n$update->{'hashtags'}";

                print "Publishing $feed_id\t$update->{'guid'}\n";

                my $post = publish_post( $content, $pod_url, $username, $password, $aspect_ids );

                # mark the item as successfully posted
                if( $post->is_success ){              
                        $sth = $dbh->prepare( "UPDATE feeds SET posted = 1 WHERE guid = \"$update->{'guid'}\"" ) or die "Can't prepare statement: $DBI::errstr";
                        $sth->execute() or die "Can't execute statement: $DBI::errstr";                                                                         
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
        my ( $db_file, $feed, $feed_id, $auto_tags, $extract_tags_from_url, $tag_categories, $extract_tags_from_title ) = @_;
        my $items = get_feed_items( $feed, $auto_tags, $extract_tags_from_url, $tag_categories, $extract_tags_from_title );  
        my $dbh = connect_to_db( $db_file );                                                       

        foreach my $item ( @$items ){
                # check to see if it exists already
                my $sth = $dbh->prepare("SELECT guid FROM feeds WHERE guid == \"$item->{'guid'}\" LIMIT 1") or die "Can't prepare statement: $DBI::errstr";
                $sth->execute() or die "Can't execute statement: $DBI::errstr";                                                                            
                my $row = $sth->fetch();                                                                                                                   

                # and if not, insert it
                unless( defined $row ){
                        $sth = $dbh->prepare( 
                                "INSERT INTO feeds( guid, feed_id, title, link, hashtags, posted, timestamp ) \
                                VALUES( \"$item->{'guid'}\", \"$feed_id\", \"$item->{'title'}\", \"$item->{'link'}\", \"" . join( ' ', @{$item->{'hashtags'}} ) . '", 0, ' . time . ')'
                        ) or die "Can't prepare statement: $DBI::errstr";                                                                                        
                        $sth->execute() or die "Can't execute statement: $DBI::errstr";                                                                          
                }                                                                                                                                                
        }                                                                                                                                                        

        $dbh->disconnect();
}                          

sub connect_to_db {
        my ( $db_file ) = @_;
        my $dbh = DBI->connect("dbi:SQLite:dbname=$db_file", '', '', { RaiseError => 1 } ) or die $DBI::errstr;

        return $dbh;
}                   

# parse the individual items from the feed
sub get_feed_items {                      
        my ( $feed, $auto_tags, $extract_tags_from_url, $tag_categories, $extract_tags_from_title ) = @_;
        my @items = ();                                                        

        foreach my $item ( @{$feed->{'channel'}->{'item'}} ){
                my $link = $item->{'link'};
                my @hashtags = ();                           
                my $guid = '';                               

                # strip trailing /
                $link =~ s/\/+$//;

                # add user-specified tags
                push( @hashtags, @$auto_tags ) if defined $auto_tags;

                # try to guess tags from the url
                if( $extract_tags_from_url ){   
                        # grab last part of url 
                        $link =~ m/\/([^\/]+)$/;
                        my $link_part = $1;     
                                                
                        # strip off any url params
                        $link_part =~ s/(\?.*)$//;

                        # split up string
                        my @parts = split( /[^A-Za-z0-9]/, $link_part );

                        push( @hashtags, @parts );
                }                                 

                # try to guess tags from the title
                if( $extract_tags_from_title ){   
                        # split up string
                        my @parts = split( /[^A-Za-z0-9]/, $item->{'title'} );

                        push( @hashtags, @parts );
                } 
                
                # try to extract tags from the feed categories (if they exist)
                if( $tag_categories and defined $item->{'category'} ){        
                        my @categories = ();                                  

                        if( ref $item->{'category'} ne 'ARRAY' ){
                                @categories = ( $item->{'category'} );
                        }                                             
                        else {                                        
                                @categories = @{$item->{'category'}}; 
                        }                                             

                        push ( @hashtags, @categories );
                }                                       

                @hashtags = sort @hashtags;

                if( defined $item->{'guid'} ){
                        if( ref $item->{'guid'} eq 'HASH' and defined $item->{'guid'}->{'content'} ){
                                $guid = $item->{'guid'}->{'content'};                                
                        }                                                                            
                        else {                                                                       
                                $guid = $item->{'guid'};                                             
                        }                                                                            
                }                                                                                    
                elsif( defined $item->{'id'} ){                                                      
                        $guid = $item->{'id'};                                                       
                }                                                                                    

                my $obj = {
                        guid            => $guid,
                        link            => $link,
                        hashtags        => hashtagify( \@hashtags ),
                };                                                  

                $items[@items] = $obj;
        }                             

        return \@items;
}                      

# fetch the feed and convert the XML to an data object
sub fetch_feed {                                      
        my ( $feed_url, $user_agent_string ) = @_;    
        my $ua = LWP::UserAgent->new();               

        $ua->agent( $user_agent_string ) if defined $user_agent_string;

        my $response = $ua->get( $feed_url );

        if( $response->is_success ){
                return ( 1, XMLin $response->decoded_content );
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
                # remove non-alphanumerics and spaces
                $item =~ s/[^A-Za-z0-9]//g;   

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
        my ( $content, $pod_url, $username, $password, $aspect_ids ) = @_;
        my $posted = 0;                                                   

        # create our user agent
        my $ua = LWP::UserAgent->new( requests_redirectable => [ 'GET', 'HEAD', 'POST' ] );

        # initialize an empty cookie jar
        $ua->cookie_jar( {} );          

        # log in
        my $login_response = login( $ua, $pod_url, $username, $password ) ;

        # if we've logged in successfully, post the message
        if( $login_response->is_success ){                 
                my $post = post_message( $ua, $pod_url, $content, $aspect_ids );
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
        $html =~ m/meta content="([^"]+)" name="csrf-param"/;
        $csrf->{'param'} = decode_entities( $1 ) if defined ( $1 );
        $html =~ m/meta content="([^"]+)" name="csrf-token"/;      
        $csrf->{'token'} = decode_entities( $1 ) if defined ( $1 );

        return $csrf if defined $csrf->{'param'} and defined $csrf->{'token'};
}                                                                             

# make any necessary string manipulations to play nice with markdown
sub format_content {
        my ( $content ) = @_;

        $content =~ s/\n/\n\n/g;
        $content .= "\n\nposted by [#pod_feeder](https://github.com/rev138/pod_feeder)";

        return $content;
}

# post a message
sub post_message {
        my ( $ua, $base_url, $content, $aspect_ids ) = @_;
        my ( $get_stream, $result ) = get_page( $ua, "$base_url/stream" );

        if( $get_stream ){
                my $csrf = extract_token( $result );
                my $post_url = "$base_url/status_messages";
                my $message = { status_message => { text => format_content( $content ) }, aspect_ids => $aspect_ids, 'status_message[provider_display_name]' => 'https://github.com/rev138/pod_feeder' };
                my $json = JSON->new->allow_nonref;

                $json = $json->utf8(0) unless utf8::is_utf8( $message );

                my $json_message = $json->encode( $message );


                return $ua->post( $post_url, 'Content' => $json_message, 'Content-Type' => 'application/json; charset=UTF-8', 'X-CSRF-Token' => $csrf->{'token'}  );
        }

}

sub usage {
        print "$0\n";
        print "usage:\n";
        print "    -a   --aspect-id <id>                Aspects to share with. May specify multiple times (default: 'public')\n";
        print "    -c   --category-tags                 Attempt to automatically hashtagify RSS item 'categories' (default: off)\n";
        print "    -d   --database <sqlite file>        The SQLite file to store feed data (default: 'feed.db')\n";
        print "    -e	 --title-tags			 Automatically hashtagify RSS item title\n";
        print "    -f   --feed-url <http://...>         The feed URL\n";
        print "    -g   --user-agent <string>           Use this to spoof the user-agent if the feed blocks bots (ex: 'Mozilla/5.0')\n";
        print "    -i   --feed-id <string>              An arbitrary identifier to associate database entries with this feed\n";
        print "    -l   --pod-url <https://...>         The pod URL\n";
        print "    -m   --timeout <hours>               How long (in hours) to keep attempting failed posts (default 72)\n";
        print "    -o   --fetch-only                    Don't publish to Diaspora, just queue the new feed items for later\n";
        print "    -p   --password <********>           The D* user password\n";
        print "    -r   --url-tags                      Attempt to automatically hashtagify the RSS link URL (default: off)\n";
        print "    -t   --auto-tag <#hashtag>           Hashtags to add to all posts. May be specified multiple times (default: none)\n";
        print "    -u   --username <user>               The D* login username\n";
        print "\n";

        exit;
}
