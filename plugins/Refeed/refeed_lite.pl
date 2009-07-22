# ===========================================================================
# A Movable Type plugin to pull in RSS and Atom feeds automatically.
# Copyright 2008 Mark Stosberg <mark.stosberg.com>.
#
# Added the ability to specify authors and category per feed.
# Copyright 2009 Everitz Consulting <everitz.com>.
# ===========================================================================
package MT::Plugin::Refeed_Lite;
use strict;
use warnings;

use base qw( MT::Plugin );

our $VERSION = '1.1';
my $plugin = MT::Plugin::Refeed_Lite->new({
    id                      => 'refeed_lite',
    name                    => 'Refeed_Lite',
    version                 => $VERSION,
    author_name             => 'Mark Stosberg',
    author_link             => 'http://mark.stosberg.com/bike',
    settings                => new MT::PluginSettings([
        [ 'feeds',    { Default => {
            'foo' => {
                'author' => '',
                'category' => '',
                'uri' => '',
            }}, Scope => 'blog' } ],
        [ 'category', { Default => '', Scope => 'blog' } ],
        [ 'author',   { Default => '', Scope => 'blog' } ],
    ]),
    description             => 'Refeed Lite allows you to pull in RSS and Atom feeds automatically into your Movable Type-powered blog.',
});
MT->add_plugin( $plugin );

sub init_registry {
    my $plugin = shift;
    $plugin->registry({
        tasks => {
            CheckFeeds => {
                label       => 'Check for updates to feeds (Refeed Lite)',
                frequency   => 60 * 60,
                code        => sub {
                    check_feeds( $plugin );
                },
            },
        },
    });
}


sub save_config {
    my $plugin = shift;
    my( $param, $scope ) = @_;
    my $pdata = $plugin->get_config_obj( $scope );
    my $data = $pdata->data( ) || {};
    my $feeds = {};

    foreach my $k ( keys %$param ) {
        if ( $k =~ m/^refeed_uri_(\d+)/ ) {
            my $num = $1;
            my $uri = $param->{"refeed_uri_$num"};
            next unless $uri;
            $feeds->{$param->{$k}} = {
                author => $param->{"refeed_author_$num"},
                category => $param->{"refeed_category_$num"},
                uri => $param->{"refeed_uri_$num"},
            };
        }
        if ( $k =~ m/^refeed_category$/ ) {
            $data->{category} = $param->{'refeed_category'};
        }
        if ( $k =~ m/^refeed_author$/ ) {
            $data->{author} = $param->{'refeed_author'};
        }
    }

    $data->{feeds} = $feeds;
    $pdata->data( $data );
    delete $plugin->{__config_obj} if exists $plugin->{__config_obj};
    $pdata->save() or die $pdata->errstr;
}

sub config_template {
    my $plugin = shift;
    my( $param, $scope ) = @_;
    my $feeds = $plugin->get_config_value( 'feeds', $scope ) || {};
    $param->{feed_count} = keys %$feeds;
    my $f = 0;
    my @data;
    if ($scope =~ /blog:(\d+)/) {
        my $blog_id = $1;
        $param->{blog_id} = $blog_id;
        $param->{category_loop} = _category_loop( $blog_id );
        $param->{author_loop} = _author_loop( $blog_id );
        foreach my $name ( sort keys %$feeds ) {
            my $feed = $feeds->{$name};
            $f++;
            # push @data, { num => $f, uri => $name, %$feed };
            push @data, {
                num => $f,
                uri => $name,
                authors => _author_loop( $blog_id, $feeds->{$name}{'author'} ),
                categories => _category_loop( $blog_id, $feeds->{$name}{'category'} ),
                %$feed
            };
        }
    }
    $param->{connection_loop} = \@data;
    if ( $scope eq 'system' ) {
        $plugin->load_tmpl( 'blah_config.tmpl' ); # not available at system level;
    } else {
        $plugin->load_tmpl( 'blog_config.tmpl' ); # $plugin->SUPER::load_config(@_);
    }
}

sub check_feeds {
    my $plugin = shift;

    require DB_File;
    require Encode;
    require XML::FeedPP;

    require File::Spec;
    my $history = File::Spec->catfile(
        MT->instance->static_file_path, 'support', 'refeed-lite-history.db'
    );
    tie my %seen, 'DB_File', $history
        or die "Can't create history database $history: $!";

    my $warn = sub {
        my $log = MT::Log->new;
        $log->message( 'Refeed Lite: ' . $_[0] );
        $log->level( MT::Log->WARNING );
        MT->log( $log );
    };

    require MT::Author;
    require MT::Blog;
    my $iter = MT::Blog->search;
    while ( my $blog = $iter->() ) {
        my $feeds = $plugin->get_config_value( 'feeds', 'blog:' . $blog->id );

        # load feed data
        my %refeed;
        my $f = 0;
        foreach my $feed ( sort keys %$feeds ) {
            $f++;
            $refeed{'uri-'.$f} = $feed;
            MT->log('uri: '.$refeed{'uri-'.$f});
            $refeed{'category-'.$f} = $feeds->{$feed}->{category};
            MT->log('category: '.$refeed{'category-'.$f});
            $refeed{'author-'.$f} = $feeds->{$feed}->{author};
            MT->log('author: '.$refeed{'author-'.$f});
        }

        # check for feeds
        unless ($f) {
            $warn->("No feeds defined for blog " . $blog->name);
            next;
        }

        # get default category (id) for blog
        my $cat_default = $plugin->get_config_value( 'category', 'blog:' . $blog->id )
            or $warn->('No default category defined for blog ' . $blog->name), next;

        # get default author (id) for blog
        my $auth_default = $plugin->get_config_value( 'author', 'blog:' . $blog->id )
            or $warn->('No default author defined for blog ' . $blog->name), next;

        for ( my $x = 1; $x <= $f; $x++ ) {
            # get feed uri
            my $uri = $refeed{'uri-'.$x};

            # get category id for this feed
            my $cat_id = $refeed{'category-'.$x};

            # load category, use default if empty
            require MT::Category;
            my $cat = MT::Category->load($cat_id);

            # load default category id unless $cat
            unless ( $cat ) {
                $cat = MT::Category->load($cat_default);
            }

            # still no $cat, send an error message
            unless ( $cat ) {
                $warn->('No category or default category record found');
                next;
            }

            # get author, use default id if empty
            my $auth_id = $refeed{'author-'.$x};

            # load author, use default if empty
            require MT::Author;
            my $author = MT::Author->load($auth_id);

            # load default author id unless $author
            unless ( $author ) {
                $author = MT::Author->load($auth_default);
            }

            # still no $author, send an error message
            unless ( $author ) {
                $warn->('No author or default author record found');
                next;
            }

            # everything is copasetic, let's look for some data
            my $feed;
            eval { $feed = XML::FeedPP->new($uri) };
            if ($@) {
                $warn->("Can't find any feeds for $uri, skipping: $@");
                next;
            }

            for my $entry ($feed->get_item()) {
                my $entry_id = $entry->guid || $entry->link;

                next if $seen{ $blog->id . $entry_id };

                my $id_in_mt = post_to_mt( $author, $blog, $feed, $entry, $cat );
                MT->log(
                    sprintf "Refeed Lite: Posted entry %s ('%s') as entry %d",
                        $entry_id, $entry->title, $id_in_mt,
                );
                $seen{ $blog->id . $entry_id } = $id_in_mt;
            }
        }
    }
}

sub post_to_mt {
    my( $author, $blog, $feed, $feed_item, $category ) = @_;

#    ## Ensure time is set properly by converting to UTC here.
#    my $issued = $feed_item->pubDate;

    my $content = sprintf <<HTML, $feed_item->description, $feed_item->link, $feed->link, $feed->title;
%s

<p>Read <a href="%s">this entry</a> on <a href="%s">%s</a>.</p>
HTML

    require MT::Permission;
    my( $perms ) = MT::Permission->search({
        author_id   => $author->id,
        blog_id     => $blog->id,
    });

    my $date = _get_mt_date($feed_item->pubDate);

    require MT::Entry;
    my $new_entry = MT::Entry->new();
    $new_entry->title( $feed_item->title );
    $new_entry->text( $feed_item->description );
    $new_entry->author_id( $author->id );
    $new_entry->blog_id($blog->id);
    $new_entry->status( 2 ); # Go straight to 'published';
    $new_entry->authored_on( $date  );
    $new_entry->keywords( $feed_item->link );
    $new_entry->save
      or return 0;

    MT->log( sprintf "Refeed Lite: entry %s had date of %s", $new_entry->title, $date,);

    my $cat;
    my $place;
    if ( $category ) {
        require MT::Category;
        $cat = MT::Category->load( { label => $category } );
        # This would create the category if it doesn't already exist.
        # unless ($cat) {
        #     if ( $perms->can_edit_categories ) {
        #         $cat = MT::Category->new();
        #         $cat->blog_id($blog->id);
        #         $cat->label( $category );
        #         $cat->parent(0);
        #         $cat->save
        #           or die $cat->errstr;
        #     }
        # }

        if ($cat) {
            require MT::Placement;
            $place = MT::Placement->new;
            $place->entry_id( $new_entry->id );
            $place->blog_id($blog->id);
            $place->category_id( $cat->id );
            $place->is_primary(1);
            $place->save
              or die $place->errstr;
        }

        MT->rebuild_entry(
            Entry             => $new_entry,
            BuildDependencies => 1,
        );
    }

# my $id = metaWeblog->newPost(
#         $blog->id,
#         '',
#         '',
#         {
#             title               => $feed_item->title,
#             description         => $feed_item->description,
#             #dateCreated         => $issued->iso8601 . 'Z',
#             dateCreated         => $feed_item->pubDate,
#             mt_convert_breaks   => 0,
#             mt_keywords         => $feed_item->link,
#         },
#         1,
#     );

    return $new_entry->id;
}

sub _author_loop {
    my( $blog_id, $auth_id ) = @_;
    my( %authors, @tmpl, $tmpl );
    require MT::Author;
    require MT::Permission;
    %authors = map { $_->id => $_->name } MT::Author->load(
        { type => MT::Author::AUTHOR( ) },
        {
            'join' => MT::Permission->join_on(
                'author_id', { blog_id => $blog_id }
            )
        }
    );
    my $set;
    if ( $auth_id ) {
        $set = $auth_id;
    } else {
        $set = $plugin->get_config_value( 'author', 'blog:'.$blog_id );
    }
    push @tmpl, qq{<option value="0">Select</option>};
    foreach my $key ( sort { $authors{$a} cmp $authors{$b} } keys %authors ) {
        my $sel = qq{selected="selected"} if ( $key eq $set );
        my $name = $authors{$key};
        push @tmpl, qq{<option value="$key" $sel>$name</option>};
    }
    foreach (@tmpl) { $tmpl .= $_."\n"; }
    return $tmpl;
}

sub _category_loop {
    my( $blog_id, $cat_id ) = @_;
    my( %cats, @tmpl, $tmpl );
    require MT::Category;
    %cats = map { $_->id => $_->label } MT::Category->load(
        { blog_id => $blog_id }
    );
    my $set;
    if ( $cat_id ) {
        $set = $cat_id;
    } else {
        $set = $plugin->get_config_value( 'category', 'blog:'.$blog_id );
    }
    push @tmpl, qq{<option value="0">Select</option>};
    foreach my $key ( sort { $cats{$a} cmp $cats{$b} } keys %cats ) {
        my $sel = qq{selected="selected"} if ( $key eq $set );
        my $name = $cats{$key};
        push @tmpl, qq{<option value="$key" $sel>$name</option>};
    }
    foreach (@tmpl) { $tmpl .= $_."\n"; }
    return $tmpl;
}

# Convert our date format into what MT expects
sub _get_mt_date {
    my$w3cdtf_date = shift;
    return unless defined $w3cdtf_date;

    my $w3cdtf_regexp = qr{
    ^(\d+)-(\d+)-(\d+)
    (?:T(\d+):(\d+)(?::(\d+)(?:\.\d*)?\:?)?\s*
    ([\+\-]\d+:?\d{2})?|$)
    }x;
    my ( $year, $mon, $mday, $hour, $min, $sec, $tz ) = ( $w3cdtf_date =~ $w3cdtf_regexp );
    # XXX We could calculate timezone offset here.
    return unless ( $year > 1900 && $mon && $mday );
    $hour ||= 0;
    $min ||= 0;
    $sec ||= 0;

    # Building this format: YYYYMMDDHHMMSS
    return sprintf( '%04d%02d%02d%02d%02d%02d', $year, $mon, $mday, $hour, $min, $sec );

}

1;
