## @file
# This file contains the implementation of the article model.
#
# @author  Chris Page &lt;chris@starforge.co.uk&gt;
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

## @class
package Newsagent::System::Article;

use strict;
use experimental 'smartmatch';
use base qw(Webperl::SystemModule); # This class extends the system module class
use v5.12;

use DateTime;
use Webperl::Utils qw(path_join hash_or_hashref);
use Newsagent::System::Images;
use Newsagent::System::Files;
use Data::Dumper;

# ============================================================================
#  Constructor

## @cmethod $ new(%args)
# Create a new Article object to manage article creation, updating, and retrieval.
# The minimum values you need t provide are:
#
# * dbh       - The database handle to use for queries.
# * settings  - The system settings object
# * metadata  - The system Metadata object.
# * roles     - The system Roles object.
# * logger    - The system logger object.
#
# @param args A hash of key value pairs to initialise the object with.
# @return A new Article object, or undef if a problem occured.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = $class -> SUPER::new(@_)
        or return undef;

    # Check that the required objects are present
    return Webperl::SystemModule::set_error("No metadata object available.") if(!$self -> {"metadata"});
    return Webperl::SystemModule::set_error("No roles object available.")    if(!$self -> {"roles"});

    $self -> {"images"} = Newsagent::System::Images -> new(dbh      => $self -> {"dbh"},
                                                           settings => $self -> {"settings"},
                                                           logger   => $self -> {"logger"},
                                                           magic    => $self -> {"magic"})
        or return Webperl::SystemModule::set_error("Images initialisation failed: ".$Webperl::SystemModule::errstr);

    $self -> {"files"} = Newsagent::System::Files -> new(dbh      => $self -> {"dbh"},
                                                         settings => $self -> {"settings"},
                                                         logger   => $self -> {"logger"},
                                                         magic    => $self -> {"magic"})
        or return Webperl::SystemModule::set_error("Files initialisation failed: ".$Webperl::SystemModule::errstr);

    # Allowed sort fields
    $self -> {"allowed_fields"} = {"creator_id"   => "creator_id",
                                   "created"      => "created",
                                   "title"        => "title",
                                   "release_mode" => "release_mode",
                                   "release_time" => "release_time",
    };

    # quick convert from release mode to relmode field
    $self -> {"relmode_lookup"} = { 'hidden'  => 0,
                                    'visible' => 0,
                                    'timed'   => 0,
                                    'draft'   => 0,
                                    'preset'  => 0,
                                    'edited'  => 0,
                                    'deleted' => 0,
                                    'next'    => 1,
                                    'after'   => 1,
                                    'nldraft' => 1,
                                    'used'    => 1
    };

    return $self;
}


# ============================================================================
#  Data access

## @method $ get_all_levels()
# Obtain the list of article levels supported by the system. This returns a list
# of supported article levels, even if the user does not have permission to post
# at that level in any of their permitted feeds. Use get_users_levels to obtain
# a list of levels the user hash access to.
#
# @return A reference to an array of hashrefs. Each hashref contains a level
#         available in the system as a pair of key/value pairs.
sub get_all_levels {
    my $self   = shift;

    $self -> clear_error();

    my $levelsh = $self -> {"dbh"} -> prepare("SELECT * FROM `".$self -> {"settings"} -> {"database"} -> {"levels"}."`
                                               ORDER BY `id`");
    $levelsh -> execute()
        or return $self -> self_error("Unable to execute user levels query: ".$self -> {"dbh"} -> errstr);

    my @levellist = ();
    while(my $level = $levelsh -> fetchrow_hashref()) {
        push(@levellist, {"name"       => $level -> {"description"},
                          "value"      => $level -> {"level"},
                          "capability" => $level -> {"capability"}});
    }

    return \@levellist;
}


## @method $ get_user_levels($feeds, $levels, $userid)
# Generate a hash representing the posting levels available to a user
# for each feed in the system.
#
# @param feeds         A reference to an array of feed hashes, as returned by get_user_feeds()
# @param levels        A reference to an array of levels, as returned by get_all_levels()
# @param userid        The ID of the user.
# @return A reference to a hash of user feed/level permissions on succes,
#         undef on error.
sub get_user_levels {
    my $self   = shift;
    my $feeds  = shift;
    my $levels = shift;
    my $userid = shift;
    my $userlevels = {};

    # Fetch the user's capabilities for each feed
    foreach my $feed (@{$feeds}) {
        my $capabilities = $self -> {"roles"} -> user_capabilities($feed -> {"metadataid"}, $userid);

        # And for each level, record whether they have the capability required to use the level
        foreach my $level (@{$levels}) {
            $userlevels -> {$feed -> {"id"}} -> {$level -> {"value"}} = $capabilities -> {$level -> {"capability"}} || 0;
        }
    }

    return $userlevels;
}


## @method $ find_articles($settings)
#
sub find_articles {
    my $self     = shift;
    my $settings = shift;

}


## @method $ get_feed_articles($settings)
# Obtain the details of articles from the database. This will search the database
# using the specified parameters, and return a reference to an array of records
# containing matching data. The following settings may be specified in the settings
# argument:
#
# - `id`: The ID of the article to retrieve, or a reference to an array of IDs. Note
#   that, even it this only matches one record, the returned value is still a
#   reference to an array of hashrefs. If an `id` is specified, all other settings
#   are ignored - if a specified id corresponds to a valid article, it will be returned,
#   regardless of which feed, level, or date it was published with. If this is a
#   scalar, the article with the ID is returned; if it is an arrayref multiple articles
#   can be requested.
# - `levels`: obtain articles that are visible at the named levels. This should be
#   a reference to an array of level names, not level ids, for readability. Valid levels are
#   defined in the `levels` table. Unknown/invalid levels will produce no matches.
#   If no level is specified, all levels are matched.
# - `feeds`: obtain articles published by the specified feed or feeds. This should be
#   a reference to an array of feed names, and valid feeds are defined in the `feeds`
#   table. If no feeds or feedids are specified, all feeds with messages at the
#   current level are matched. If specified, any feedid array specified is ignored.
# - `feedids`: a reference to an array of feed ids.
# - `maxage`:
# - `count`: how many articles to return. If not specified, this defaults to the
#   system-wide setting defined in `Feed:count` in the settings table.
# - `offset`: article offset, first returned article is at offset 0.
# - `fulltext_mode`: if specified, the full article text will be included in the result,
#   otherwise only the title and summary will be included.
# - `use_fulltext_desc`: if specfied, a flag with the same name will be set in each
#   article indicating that the fulltext should be used as the description.
# - `allow_invisible`: if true, allow
#
# @param settings A reference to a hash containing settings for the query.
# @return A reference to an array of record hashes on success, undef on error.
sub get_feed_articles {
    my $self     = shift;
    my $settings = hash_or_hashref(@_);
    my @params;

    $self -> clear_error();

    # Fix up defaults
    $settings -> {"count"} = $self -> {"settings"} -> {"config"} -> {"Feed:count"}
        if(!$settings -> {"count"});

    $settings -> {"offset"} = 0
        if(!$settings -> {"offset"});

    # Clear outdated sticky values
    $self -> _clear_sticky()
        or return undef;

    # Now start constructing the query. These are the tables and where clauses that are
    # needed regardless of the settings provided by the caller.
    # All the fields the query is interested in, normally fulltext is omitted unless explicitly requested
    my $fields = "`article`.`id`,
                  `user`.`user_id` AS `userid`, `user`.`username` AS `username`, `user`.`realname` AS `realname`, `user`.`email`,
                  `article`.`created`,
                  `article`.`title`,
                  `article`.`summary`,
                  `article`.`release_mode`,
                  `article`.`release_time`,
                  `article`.`is_sticky`,
                  `article`.`sticky_until`,
                  `article`.`full_summary`";
    $fields   .= ", `article`.`article` AS `fulltext`" if($settings -> {"fulltext_mode"});

    my $from  = "`".$self -> {"settings"} -> {"database"} -> {"articles"}."` AS `article`
                 LEFT JOIN `".$self -> {"settings"} -> {"database"} -> {"users"}."` AS `user`
                     ON `user`.`user_id` = `article`.`creator_id`";

    my $where;
    if($settings -> {"allow_invisible"}) {
        # Initial where clause that includes all articles except deleted ones
        $where = "`article`.`release_mode` != 'deleted'"

    } else {
        # Initial where clause that only includes articles that are explicitly visible, or have passed
        # their timed release threshold - this will block deleted/edited/etc
        $where = "(`article`.`release_mode` = 'visible'
                    OR (`article`.`release_mode` = 'timed'
                         AND `article`.`release_time` <= UNIX_TIMESTAMP()
                       )
                  )";
    }

    # If an article ID is specified, no further filtering should be done - if the ID corresponds
    # to a visible article, the feed, level, or anything else doesn't matter.
    if($settings -> {"id"}) {
        if(ref($settings -> {"id"}) eq "ARRAY" && scalar(@{$settings -> {"id"}})) {
            $where .= " AND `article`.`id` IN (?".(",?" x (scalar(@{$settings -> {"id"}}) - 1)).")";
            push(@params, @{$settings -> {"id"}});
        } else {
            $where .= " AND `article`.`id` = ?";
            push(@params, $settings -> {"id"});
        }
    } else {

        # There can be multiple feeds specified.
        if($settings -> {"feeds"} && scalar(@{$settings -> {"feeds"}})) {
            my $feedfrag = "";

            foreach my $feed (@{$settings -> {"feeds"}}) {
                $feedfrag .= " OR " if($feedfrag);
                $feedfrag .= "`feed`.`name` LIKE ?";
                push(@params, $feed);
            }

            $from  .= ", `".$self -> {"settings"} -> {"database"} -> {"feeds"}."` AS `feed`,
                         `".$self -> {"settings"} -> {"database"} -> {"articlefeeds"}."` AS `artfeeds`";
            $where .= " AND ($feedfrag)
                        AND `artfeeds`.`article_id` = `article`.`id`
                        AND `artfeeds`.`feed_id` = `feed`.`id`";

        } elsif($settings -> {"feedids"} && scalar(@{$settings -> {"feedids"}})) {
            $from  .= ", `".$self -> {"settings"} -> {"database"} -> {"articlefeeds"}."` AS `artfeeds`";

            $where .= " AND `artfeeds`.`feed_id` IN (?".(",?" x (scalar(@{$settings -> {"feedids"}}) - 1)).")
                        AND `artfeeds`.`article_id` = `article`.`id`";
            push(@params, @{$settings -> {"feedids"}});
        }

        # Level filtering
        if($settings -> {"levels"} && scalar(@{$settings -> {"levels"}})) {
            my $levelfrag = "";

            foreach my $level (@{$settings -> {"levels"}}) {
                $levelfrag .= " OR " if($levelfrag);
                $levelfrag .= "`level`.`level` = ?";
                push(@params, $level);
            }

            $from  .= ", `".$self -> {"settings"} -> {"database"} -> {"levels"}."` AS `level`,
                         `".$self -> {"settings"} -> {"database"} -> {"articlelevels"}."` AS `artlevels`";
            $where .= " AND ($levelfrag)
                        AND `artlevels`.`article_id` = `article`.`id`
                        AND `artlevels`.`level_id` = `level`.`id`";
        }

        if($settings -> {"maxage"}) {
            $where .= " AND (`article`.`release_time` > ?
                             OR
                             (`article`.`is_sticky` AND `article`.`sticky_until` > UNIX_TIMESTAMP()))";
            push(@params, $settings -> {"maxage"});
        }

        if($settings -> {"mindate"} && $settings -> {"maxdate"}) {
            $where .= " AND `article`.`release_time` >= ?
                        AND `article`.`release_time` <= ?";
            push(@params, $settings -> {"mindate"}, $settings -> {"maxdate"});
        }
    }

    my $ordering = "";
    given($settings -> {"order"}) {
        when("asc.nosticky" ) { $ordering = "`article`.`release_time` ASC"; }
        when("asc.sticky")    { $ordering = "`article`.`is_sticky` ASC, `article`.`release_time` ASC"; }
        when("desc.nosticky") { $ordering = "`article`.`release_time` DESC"; }
        when("desc.sticky")   { $ordering = "`article`.`is_sticky` DESC, `article`.`release_time` DESC"; }
        default {
            $ordering = "`article`.`is_sticky` DESC, `article`.`release_time` DESC";
        }
    }

    my $sql = "SELECT DISTINCT $fields
               FROM $from
               WHERE $where
               ORDER BY $ordering
               LIMIT ".$settings -> {"offset"}.", ".$settings -> {"count"};

    # Now put it all together and fire it at the database
    my $query = $self -> {"dbh"} -> prepare($sql);
    $query -> execute(@params)
        or return $self -> self_error("Unable to execute article query: ".$self -> {"dbh"} -> errstr);

    # Fetch all the matching articles, and if there are any go and shove in the level list, images, files and other info
    my $articles = $query -> fetchall_arrayref({});
    if(scalar(@{$articles})) {
        my $levelh = $self -> {"dbh"} -> prepare("SELECT `level`.`level`
                                                  FROM `".$self -> {"settings"} -> {"database"} -> {"levels"}."` AS `level`,
                                                       `".$self -> {"settings"} -> {"database"} -> {"articlelevels"}."` AS `artlevels`
                                                  WHERE `level`.`id` = `artlevels`.`level_id`
                                                  AND `artlevels`.`article_id` = ?");

        my $feedh = $self -> {"dbh"} -> prepare("SELECT `feed`.*
                                                  FROM `".$self -> {"settings"} -> {"database"} -> {"feeds"}."` AS `feed`,
                                                       `".$self -> {"settings"} -> {"database"} -> {"articlefeeds"}."` AS `artfeeds`
                                                  WHERE `feed`.`id` = `artfeeds`.`feed_id`
                                                  AND `artfeeds`.`article_id` = ?
                                                  ORDER BY `feed`.`name`");

        my $imageh = $self -> {"dbh"} -> prepare("SELECT `artimgs`.`image_id`, `artimgs`.`order`
                                                  FROM `".$self -> {"settings"} -> {"database"} -> {"articleimages"}."` AS `artimgs`
                                                  WHERE `artimgs`.`article_id` = ?
                                                  ORDER BY `artimgs`.`order`");

        my $fileh = $self -> {"dbh"} -> prepare("SELECT `artfiles`.`file_id`, `artfiles`.`order`
                                                 FROM `".$self -> {"settings"} -> {"database"} -> {"articlefiles"}."` AS `artfiles`
                                                 WHERE `artfiles`.`article_id` = ?
                                                 ORDER BY `artfiles`.`order`");

        foreach my $article (@{$articles}) {
            $levelh -> execute($article -> {"id"})
                or return $self -> self_error("Unable to execute article level query for article '".$article -> {"id"}."': ".$self -> {"dbh"} -> errstr);

            $feedh -> execute($article -> {"id"})
                or return $self -> self_error("Unable to execute article feed query for article '".$article -> {"id"}."': ".$self -> {"dbh"} -> errstr);

            # Need to copy the mode to each article.
            $article -> {"fulltext_mode"} = $settings -> {"fulltext_mode"};
            $article -> {"use_fulltext_desc"} = $settings -> {"use_fulltext_desc"};

            $article -> {"levels"} = $levelh -> fetchall_arrayref({});
            $article -> {"feeds"}  = $feedh -> fetchall_arrayref({});

            # Pull in the image data
            $imageh -> execute($article -> {"id"})
                or return $self -> self_error("Unable to execute article image query for article '".$article -> {"id"}."': ".$self -> {"dbh"} -> errstr);

            $article -> {"images"} = [];
            # Place the images into the images array based using the order as the array position
            while(my $image = $imageh -> fetchrow_hashref()) {
                my $data = $self -> {"images"} -> get_image_info($image -> {"image_id"}, $image -> {"order"});

                $article -> {"images"} -> [$image -> {"order"}] = $data
                    if($data && $data -> {"id"});
            }

            # Pull in the file data
            $fileh -> execute($article -> {"id"})
                or return $self -> self_error("Unable to execute article file query for article '".$article -> {"id"}."': ".$self -> {"dbh"} -> errstr);

            $article -> {"files"} = [];
            # Place the files into the files array based using the order as the array position
            while(my $file = $fileh -> fetchrow_hashref()) {
                my $data = $self -> {"files"} -> get_file_info($file -> {"file_id"}, $file -> {"order"});

                $article -> {"files"} -> [$file -> {"order"}] =  $data
                    if($data && $data -> {"id"});
            }

            # Fetch the year info
            $article -> {"acyear"} = $self -> {"userdata"} -> get_year_data($article -> {"release_time"})
                if($self -> {"userdata"});
        }
    } # if(scalar(@{$articles})) {

    return $articles;
}


## @method $ get_user_articles($userid, $settings)
# Fetch the list of articles the user has editor access to. This will go through
# the articles in the database, ordered by the specified field, recording which
# articles the user can edit.
#
# Supported arguments in the settings are:
# - count     The number of articles to return.
# - offset    An offset to start returning articles from. The first article
#             is at offset = 0.
# - sortfield The field to sort the results on, if not specified defaults
#                  to `release_time`
# - sortdir   The direction to sort in, if not specified defaults to `DESC`,
#             valid values are `ASC` and `DESC`.
# - month     The month to fetch articles for. If not set, all months are
#             returned
# - year      The year to fetch articles for. If not set, all years are returned.
# - hidedeleted If this is set to true, deleted articles are not included,
#             regardless of the setting of `modes`.
# - users     A reference to an array of user IDs. Only articles created or edited
#             by the specified users will be included in the generated list. If
#             this is not specified, all users are included.
# - feeds     A reference to an array of feed IDs. Only articles posted in feeds
#             with at least one of these IDs will be included. If not specified,
#             articles in any feed will be included in the output.
# - levels    A reference to an array of level IDs. Only articles posted with
#             at least one of these levels will be included. If not specified,
#             articles at all levels are included.
# - modes     A reference to an array of modes to include in the list. If not
#             specified, articles with every mode are included (except for
#             'deleted' if `hidedeleted` is set)
#
# @param userid    The ID of the user requesting the article list.
# @param settings  The settings to use when fetching the article list.
# @return A reference to a hash containing a reference to an array of articles
#         the user can edit, and a metadata hash containing the count of the
#         number of articles the user can edit (which may be larger than the size
#         of the returned array, if `count` is specified), the feeds present in
#         the list the user can see, and the users present in the list the user
#         can see.
sub get_user_articles {
    my $self      = shift;
    my $userid    = shift;
    my $settings  = shift;
    my $sortfield = $settings -> {"sortfield"} || 'release_time';
    my $sortdir   = $settings -> {"sortdir"} || 'DESC';
    my @articles;

    $self -> clear_error();

    # Clear outdated sticky values
    $self -> _clear_sticky()
        or return undef;

    # Force the sortfield to a supported value
    $sortfield =  $self -> {"allowed_fields"} -> {$sortfield} || 'release_time';

    # And the sort direction too.
    $sortdir = $sortdir eq "DESC" ? "DESC" : "ASC";

    my $fields = "`article`.*, `user`.`user_id` AS `userid`, `user`.`username` AS `username`, `user`.`realname` AS `realname`, `user`.`email`";
    my $from   = "`".$self -> {"settings"} -> {"database"} -> {"articles"}."` AS `article`
                  LEFT JOIN `".$self -> {"settings"} -> {"database"} -> {"users"}."` AS `user`
                      ON `user`.`user_id` = `article`.`creator_id`";
    my $where  = $settings -> {"hidedeleted"} ? " WHERE `article`.`release_mode` != 'deleted'" : "";
    my @params;

    # handle mode limiting
    my $modelimit = $self -> _article_mode_control($settings -> {"modes"}, \@params);
    $where .= ($where ? " AND $modelimit" : "WHERE $modelimit")
        if($modelimit);

    # Handle time bounding
    my ($start, $end) = $self -> _build_articlelist_timebounds($settings -> {"year"}, $settings -> {"month"});
    if($start && $end) {
        $where .= ($where ? " AND " : "WHERE ");
        $where .= "`article`.`release_time` >= ? AND `article`.`release_time` <= ?";
        push(@params, $start, $end)
    }

    # The actual query can't contain a limit directive: there's no way to determine at this point
    # whether the user has access to any particular article, so any limit may be being applied to
    # entries the user should never even see.
    my $articleh = $self -> {"dbh"} -> prepare("SELECT $fields
                                                FROM $from
                                                $where
                                                ORDER BY `article`.`$sortfield` $sortdir, `article`.`created` $sortdir");

    my $levelh = $self -> {"dbh"} -> prepare("SELECT `level`.*
                                              FROM `".$self -> {"settings"} -> {"database"} -> {"levels"}."` AS `level`,
                                                   `".$self -> {"settings"} -> {"database"} -> {"articlelevels"}."` AS `artlevels`
                                              WHERE `level`.`id` = `artlevels`.`level_id`
                                              AND `artlevels`.`article_id` = ?");

    my $feedh = $self -> {"dbh"} -> prepare("SELECT `feed`.*
                                             FROM `".$self -> {"settings"} -> {"database"} -> {"feeds"}."` AS `feed`,
                                                  `".$self -> {"settings"} -> {"database"} -> {"articlefeeds"}."` AS `artfeeds`
                                             WHERE `feed`.`id` = `artfeeds`.`feed_id`
                                             AND `artfeeds`.`article_id` = ?
                                             ORDER BY `feed`.`name`");

    $articleh -> execute(@params)
        or return $self -> self_error("Unable to execute article query: ".$self -> {"dbh"} -> errstr);

    # Now process all the articles
    my ($added, $count, $feeds, $users) = (0, 0, {}, {});
    while(my $article = $articleh -> fetchrow_hashref()) {
        # Does the user have edit access to this article?
        if($self -> {"roles"} -> user_has_capability($article -> {"metadata_id"}, $userid, "edit")) {

            # convert the status to a mode
            $article -> {"relmode"} = $self -> {"relmode_lookup"} -> {$article -> {"release_mode"}};

            if($article -> {"relmode"} == 0) {
                # Fetch the feed information. This has to happen even if the article will not actually
                # be stored, because the feeds available needs to be recorded
                $feedh -> execute($article -> {"id"})
                    or return $self -> self_error("Unable to execute article feed query for article '".$article -> {"id"}."': ".$self -> {"dbh"} -> errstr);

                $article -> {"feeds"} = $feedh -> fetchall_arrayref({});

                # Regardless of whether this article will be included in the list, we need
                # to record its feeds as feeds the user has access to
                foreach my $feed (@{$article -> {"feeds"}}) {
                    $feeds -> {$feed -> {"id"}} = $feed
                        if(!$feeds -> {$feed -> {"id"}});
                }
            } else {
                $self -> _get_article_section($article, $article -> {"release_mode"} eq "used")
                    or return undef;
            }

            # And store the user information if needed
            $users -> {$article -> {"userid"}} = { "user_id"  => $article -> {"userid"},
                                                   "username" => $article -> {"username"},
                                                   "realname" => $article -> {"realname"}}
                if(!$users -> {$article -> {"userid"}});

            # Does the article match the filters specified?
            if($self -> _article_user_match($article, $settings -> {"users"}) &&
               $self -> _article_feed_match($article, $settings -> {"feeds"}) &&
               $self -> _article_level_match($article, $settings -> {"levels"})) {

                # If an offset has been specified, have enough articles been skipped, and if
                # a count has been specified, is there still space for more entries?
                if((!$settings -> {"offset"} || $count >= $settings -> {"offset"}) &&
                   (!$settings -> {"count"}  || $added < $settings -> {"count"})) {

                    # Yes, fetch the level information for the article
                    $levelh -> execute($article -> {"id"})
                        or return $self -> self_error("Unable to execute article level query for article '".$article -> {"id"}."': ".$self -> {"dbh"} -> errstr);

                    $article -> {"levels"} = $levelh -> fetchall_arrayref({});

                    # Yes, store it
                    push(@articles, $article);
                    ++$added; # keep a separate 'added' counter, it may be faster than scalar()
                }
                ++$count;
            }
        }
    }

    return { "articles" => \@articles,
             "metadata" => { "count" => $count,
                             "feeds" => $feeds,
                             "users" => $users
                           }
           };
}


## @method @ get_user_presets($userid)
# Fetch the list of presets the user has editor access to. This will go through
# the articles in the database, looking for presets the user can access, and
# returns an array of hashes describing them
#
# @param userid    The ID of the user requesting the article list.
# @return A reference to an array of preset information hashes on success, undef
#         on error.
sub get_user_presets {
    my $self   = shift;
    my $userid = shift;

    $self -> clear_error();

    # It's not possible to determine as part of an SQL query whether the user has access to any given article,
    # so fetch all the presets and then the system can check access
    my $articleh = $self -> {"dbh"} -> prepare("SELECT `id`, `metadata_id`, `preset`
                                                FROM `".$self -> {"settings"} -> {"database"} -> {"articles"}."`
                                                WHERE `release_mode` = 'preset'
                                                AND `preset` IS NOT NULL
                                                ORDER BY `preset`");
    $articleh -> execute()
        or return $self -> self_error("Unable to execute preset query: ".$self -> {"dbh"} -> errstr);

    my @presets = ();
    while(my $article = $articleh -> fetchrow_hashref()) {
        # Does the user have edit access to this article?
        if($self -> {"roles"} -> user_has_capability($article -> {"metadata_id"}, $userid, "edit")) {
            # Yes, record the preset
            push(@presets, $article);
        }
    }

    return \@presets;
}


## @method $ get_article($articleid)
# Obtain the data for the specified article.
#
# @param articleid The ID of the article to fetch the data for.
# @return A reference to a hash containing the article data on success, undef
#         on error
sub get_article {
    my $self      = shift;
    my $articleid = shift;

    my $fields = "`article`.*, `user`.`user_id` AS `userid`, `user`.`username` AS `username`, `user`.`realname` AS `realname`, `user`.`email`";
    my $from   = "`".$self -> {"settings"} -> {"database"} -> {"articles"}."` AS `article`
                  LEFT JOIN `".$self -> {"settings"} -> {"database"} -> {"users"}."` AS `user`
                      ON `user`.`user_id` = `article`.`creator_id`";

    # The actual query can't contain a limit directive: there's no way to determine at this point
    # whether the user has access to any particular article, so any limit may be being applied to
    # entries the user should never even see.
    my $articleh = $self -> {"dbh"} -> prepare("SELECT $fields
                                                FROM $from
                                                WHERE `article`.`id` = ?");

    my $levelh = $self -> {"dbh"} -> prepare("SELECT `level`.*
                                              FROM `".$self -> {"settings"} -> {"database"} -> {"levels"}."` AS `level`,
                                                   `".$self -> {"settings"} -> {"database"} -> {"articlelevels"}."` AS `artlevels`
                                              WHERE `level`.`id` = `artlevels`.`level_id`
                                              AND `artlevels`.`article_id` = ?");

    my $feedh = $self -> {"dbh"} -> prepare("SELECT `feed`.*
                                             FROM `".$self -> {"settings"} -> {"database"} -> {"feeds"}."` AS `feed`,
                                                  `".$self -> {"settings"} -> {"database"} -> {"articlefeeds"}."` AS `artfeeds`
                                             WHERE `feed`.`id` = `artfeeds`.`feed_id`
                                             AND `artfeeds`.`article_id` = ?
                                             ORDER BY `feed`.`name`");

    my $imageh = $self -> {"dbh"} -> prepare("SELECT `artimgs`.`image_id`, `artimgs`.`order`
                                              FROM `".$self -> {"settings"} -> {"database"} -> {"articleimages"}."` AS `artimgs`
                                              WHERE `artimgs`.`article_id` = ?
                                              ORDER BY `artimgs`.`order`");

    my $fileh = $self -> {"dbh"} -> prepare("SELECT `artfiles`.`file_id`, `artfiles`.`order`
                                             FROM `".$self -> {"settings"} -> {"database"} -> {"articlefiles"}."` AS `artfiles`
                                             WHERE `artfiles`.`article_id` = ?
                                             ORDER BY `artfiles`.`order`");

    $articleh -> execute($articleid)
        or return $self -> self_error("Unable to execute article query: ".$self -> {"dbh"} -> errstr);

    my $article = $articleh -> fetchrow_hashref()
        or return $self -> self_error("Request for non-existent article with ID $articleid");

    # convert the status to a mode
    $article -> {"relmode"} = $self -> {"relmode_lookup"} -> {$article -> {"release_mode"}};

    # For normal articles, pull in feed and level information
    if($article -> {"relmode"} == 0) {
        # Add the feed data to the article data
        $feedh -> execute($article -> {"id"})
            or return $self -> self_error("Unable to execute article feed query for article '".$article -> {"id"}."': ".$self -> {"dbh"} -> errstr);
        $article -> {"feeds"} = $feedh -> fetchall_arrayref({});

        # Add the level data to the article data
        $levelh -> execute($article -> {"id"})
            or return $self -> self_error("Unable to execute article level query for article '".$article -> {"id"}."': ".$self -> {"dbh"} -> errstr);
        $article -> {"levels"} = $levelh -> fetchall_arrayref({});

    # for newsletter articles, pull in the section data
    } else {
        $self -> _get_article_section($article, $article -> {"release_mode"} eq "used")
            or return undef;
    }

    # And add the image data
    $imageh -> execute($article -> {"id"})
        or return $self -> self_error("Unable to execute article image query for article '".$article -> {"id"}."': ".$self -> {"dbh"} -> errstr);

    my $images = $imageh -> fetchall_arrayref({});
    $article -> {"images"} = [];
    foreach my $image (@{$images}) {
        my $data = $self -> {"images"} -> get_image_info($image -> {"image_id"}, $image -> {"order"});

        $article -> {"images"} -> [$image -> {"order"}] = $data
            if($data && $data -> {"id"});
    }

    # finally, files
    $fileh -> execute($article -> {"id"})
        or return $self -> self_error("Unable to execute article file query for article '".$article -> {"id"}."': ".$self -> {"dbh"} -> errstr);

    my $files = $fileh -> fetchall_arrayref({});
    $article -> {"files"} = [];
    foreach my $file (@{$files}) {
        my $data = $self -> {"files"} -> get_file_info($file -> {"file_id"}, $file -> {"order"});

        $article -> {"files"} -> [$file -> {"order"}] = $data
            if($data && $data -> {"id"});
    }

    return $article;
}


# ==============================================================================
#  Storage and addition functions


## @method $ add_article($article, $userid, $previd, $mode, $newid)
# Add an article to the system's database. This function adds an article to the system
# using the contents of the specified hash to fill in the article fields in the db.
#
# @param article A reference to a hash containing article data, as generated by the
#                _validate_article_fields() function.
# @param userid  The ID of the user creating this article.
# @param previd  The ID of a previous revision of the article.
# @param mode    0 to indicate a normal article (the default) or 1 to indicate a
#                newsletter article. If the latter, the article should not have feed
#                or level information set, but it must have schedule and section info.
# @param newid   The ID to give the new article on creation. If not set, the next
#                available ID is used.
# @return The ID of the new article on success, undef on error.
sub add_article {
    my $self    = shift;
    my $article = shift;
    my $userid  = shift;
    my $previd  = shift;
    my $mode    = shift || 0;
    my $newid   = shift;

    $self -> clear_error();

    # Add urls to the database
    foreach my $id (keys(%{$article -> {"images"}})) {
        if($article -> {"images"} -> {$id} -> {"mode"} eq "url") {
            $article -> {"images"} -> {$id} -> {"img"} = $self -> {"images"} -> add_url($article -> {"images"} -> {$id} -> {"url"})
                or return undef;
        }
    }

    # Make a new metadata context to attach to the article
    my $metadataid = $self -> _create_article_metadata($previd, $article -> {"feeds"}, $article -> {"section"}, $mode)
        or return $self -> self_error("Unable to create new metadata context: ".$self -> {"metadata"} -> errstr());

    # Fix up release time
    my $now = time();
    $article -> {"release_time"} = $now if(!$article -> {"release_time"});

    my ($is_sticky, $sticky_until) = (0, undef);
    if($article -> {"sticky"}) {
        $is_sticky = 1;
        $sticky_until = $article -> {"release_time"} + ($article -> {"sticky"} * 86400)
    }

    my $full_summary = $article -> {"full_summary"} ? 1 : 0;

    # Add the article itself
    my $addh = $self -> {"dbh"} -> prepare("INSERT INTO `".$self -> {"settings"} -> {"database"} -> {"articles"}."`
                                            (id, previous_id, metadata_id, creator_id, created, title, summary, article, preset, release_mode, release_time, updated, updated_id, sticky_until, is_sticky, full_summary)
                                            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)");
    my $rows = $addh -> execute($newid, $previd, $metadataid, $userid, $now, $article -> {"title"}, $article -> {"summary"}, $article -> {"article"}, $article -> {"preset"}, $article -> {"release_mode"}, $article -> {"release_time"}, $now, $userid, $sticky_until, $is_sticky, $full_summary);
    return $self -> self_error("Unable to perform article insert: ". $self -> {"dbh"} -> errstr) if(!$rows);
    return $self -> self_error("Article insert failed, no rows inserted") if($rows eq "0E0");

    # MYSQL: This ties to MySQL, but is more reliable that last_insert_id in general.
    #        Try to find a decent solution for this mess...
    # NOTE: the DBD::mysql documentation doesn't actually provide any useful information
    #       about what this will contain if the insert fails. In fact, DBD::mysql calls
    #       libmysql's mysql_insert_id(), which returns 0 on error (last insert failed).
    #       There, why couldn't they bloody /say/ that?!
    $newid = $self -> {"dbh"} -> {"mysql_insertid"}
        if(!$newid);

    return $self -> self_error("Unable to obtain id for new article row")
        if(!$newid);

    # Now set up image, file, feed, and level associations
    $self -> {"images"} -> add_image_relation($newid, $article -> {"images"} -> {"a"} -> {"img"}, 0) or return undef
        if($article -> {"images"} -> {"a"} -> {"img"});

    $self -> {"images"} -> add_image_relation($newid, $article -> {"images"} -> {"b"} -> {"img"}, 1) or return undef
        if($article -> {"images"} -> {"b"} -> {"img"});

    # Add file relations
    if($article -> {"files"} && scalar(@{$article -> {"files"}})) {
        my $order = 0;
        foreach my $file (@{$article -> {"files"}}) {
            $self -> {"files"} -> add_file_relation($newid, $file -> {"id"}, $order++)
                or return $self -> self_error($self -> {"files"} -> errstr());
        }
    }

    # Normal articles need feed and level relations
    if($mode == 0) {
        $self -> {"feed"} -> add_feed_relations($newid, $article -> {"feeds"})
            or return $self -> self_error($self -> {"feed"} -> errstr());

        $self -> _add_level_relations($newid, $article -> {"levels"})
            or return undef;

        # Get the override flag
        my $override = $self -> {"feed"} -> get_feed_override($article -> {"feeds"});
        $self -> _set_overide_flag($newid, 1)
            if($override);

    # While newsletter articles need schedule/section
    } else {
        $self -> {"schedule"} -> add_section_relation($newid, $article -> {"schedule_id"}, $article -> {"section"}, $article -> {"sort_order"})
            or return $self -> self_error($self -> {"schedule"} -> errstr());
    }

    # Attach to the metadata context
    $self -> {"metadata"} -> attach($metadataid)
        or return $self -> self_error("Error in metadata system: ".$self -> {"metadata"} -> errstr());

    # Give the user editor access to the article
    my $roleid = $self -> {"roles"} -> role_get_roleid("editor");
    $self -> {"roles"} -> user_assign_role($metadataid, $userid, $roleid)
        or return $self -> self_error($self -> {"roles"} -> errstr());

    # Remove any autosave
    $self -> clear_autosave($userid)
        or return undef;

    return $newid;
}


## @method $ set_article_status($articleid, $newmode, $userid, $setdate)
# Update the release mode for the specified article. This will update the mode
# set for the article and change its `updated` timestamp, it may also modify
# the release time timestamp if required.
#
# @param articleid The ID of the article to update.
# @param newmode   The new mode to set for the article.
# @param userid    The ID of the user updating the article.
# @param setdate   Update the release_time to the current time.
# @return A reference to a hash containing the updated article data on success,
#         undef on error.
sub set_article_status {
    my $self      = shift;
    my $articleid = shift;
    my $newmode   = shift;
    my $userid    = shift;
    my $setdate   = shift;
    my $now = time();

    # We always set the update timestamp and status
    my @params = ($now, $newmode);
    my $set    = "`updated` = ?, `release_mode` = ?";

    # If a userid is specified, update it.
    if($userid) {
        push(@params, $userid);
        $set .= ", `updated_id` = ?";
    }

    # if the release timestamp should be updated, do so
    if($setdate) {
        push(@params, $now);
        $set .= ", `release_time` = ?";
    }

    # finally, need the article id as the last argument to the query.
    push(@params, $articleid);
    my $updateh = $self -> {"dbh"} -> prepare("UPDATE `".$self -> {"settings"} -> {"database"} -> {"articles"}."`
                                               SET $set
                                               WHERE id = ?");
    my $result = $updateh -> execute(@params);
    return $self -> self_error("Unable to update article mode: ".$self -> {"dbh"} -> errstr) if(!$result);
    return $self -> self_error("Article mode update failed: no rows updated.") if($result eq "0E0");

    return $self -> get_article($articleid);
}


## @method update_image_url($articleid, $order, $url)
# Update the URL set for the article to the url specified. If the article does
# not have a URL associated with it at the specified order, this adds the relation,
# otherwise it updates the existing URL.
#
# @param articleid The ID of the article to update the URL for.
# @param order     The image order (0 or 1)
# @param url       A URL to update for the article.
# @return true on success, undef on error.
sub update_image_url {
    my $self      = shift;
    my $articleid = shift;
    my $order     = shift;
    my $url       = shift;

    $self -> clear_error();

    # Work out the name
    my ($name) = $url =~ m|/([^/]+?)(\?.*)?$|;
    $name = "unknown" if(!$name);

    # Locate the image ID
    my $relationh = $self -> {"dbh"} -> prepare("SELECT `image_id`
                                                 FROM `".$self -> {"settings"} -> {"database"} -> {"articleimages"}."`
                                                 WHERE `article_id` = ? AND `order` = ?");
    $relationh -> execute($articleid, $order)
        or return $self -> self_error("Unable to execute image ID lookup: ".$self -> {"dbh"} -> errstr);

    my $relation = $relationh -> fetchrow_arrayref();

    # If there is no relation set for this article and order, add a new one
    if(!$relation) {
        $url = $self -> {"images"} -> add_url($url)
            or return undef;

        $self -> {"images"} -> add_image_relation($articleid, $url, $order)
            or return undef;

    # If the relation is present, update the url
    } else {
        my $imageh = $self -> {"dbh"} -> prepare("UPDATE `".$self -> {"settings"} -> {"database"} -> {"images"}."`
                                                  SET `type` = 'url', `name` = ?, `location` = ?
                                                  WHERE `id` = ?");
        my $rows = $imageh -> execute($name, $url, $relation -> [0]);
        return $self -> self_error("Unable to perform article image url update: ". $self -> {"dbh"} -> errstr) if(!$rows);
        return $self -> self_error("Article image url update failed, no rows updated") if($rows eq "0E0");
    }

    return 1;
}


## @method $ update_article_inplace($articleid, $newsettings)
# Update the title, summary, article text, and image URLs for the specified article.
#
# @note This will not work correctly if the images set for the article are not URLs
#       (ie: existing image/new image types will not work correctly)
# @todo Fix this function to support different image types.
#
# @param articleid   The ID of the article to update.
# @param newsettings The settings to apply for the article
# @return true on success, undef on error.
sub update_article_inplace {
    my $self        = shift;
    my $articleid   = shift;
    my $newsettings = shift;

    # Update the simple settings
    my $articleh = $self -> {"dbh"} -> prepare("UPDATE `".$self -> {"settings"} -> {"database"} -> {"articles"}."`
                                                SET `title` = ?, `summary` = ?, `article` = ?
                                                WHERE `id` = ?");
    my $rows = $articleh -> execute($newsettings -> {"title"}, $newsettings -> {"summary"}, $newsettings -> {"article"}, $articleid);
    return $self -> self_error("Unable to perform article update: ". $self -> {"dbh"} -> errstr) if(!$rows);
    return $self -> self_error("Article update failed, no rows updated") if($rows eq "0E0");

    $self -> update_image_url($articleid, 0, $newsettings -> {"images"} -> {"a"} -> {"url"}) or return undef
        if($newsettings -> {"images"} -> {"a"} -> {"url"});

    $self -> update_image_url($articleid, 1, $newsettings -> {"images"} -> {"b"} -> {"url"}) or return undef
        if($newsettings -> {"images"} -> {"b"} -> {"url"});

    return 1;
}


## @method $ renumber_article($articleid)
# Move the specified article to the end of the articles table. Given an article ID,
# this attempts to change the article and all associated relations and hangers-on
# so that its ID is the next available ID in the article table. This is used as
# part of the editing process to allow the specified articleid to be reused.
#
# @param articleid The ID of the article to move
# @return The ID the article has been moved to on success, undef on error.
sub renumber_article {
    my $self      = shift;
    my $articleid = shift;

    $self -> clear_error();

    # duplicate the article at the end of the table (we can't literally move
    # it, as there are potential race conditions around using the ID directly)
    my $moveh = $self -> {"dbh"} -> prepare("INSERT INTO `".$self -> {"settings"} -> {"database"} -> {"articles"}."`
                                            (previous_id, metadata_id, creator_id, created, title, summary, article, preset, release_mode, release_time, updated, updated_id, sticky_until, is_sticky, full_summary)
                                                SELECT previous_id, metadata_id, creator_id, created, title, summary, article, preset, release_mode, release_time, updated, updated_id, sticky_until, is_sticky, full_summary
                                                FROM `".$self -> {"settings"} -> {"database"} -> {"articles"}."`
                                                WHERE id = ?");
    my $rows = $moveh -> execute($articleid);
    return $self -> self_error("Unable to perform article move: ". $self -> {"dbh"} -> errstr) if(!$rows);
    return $self -> self_error("Article move failed, no rows inserted") if($rows eq "0E0");

    # Get the new ID
    my $newid = $self -> {"dbh"} -> {"mysql_insertid"}
        or return $self -> self_error("Unable to obtain id for new article row");

    # Update the relation IDs
    $self -> _change_article_relation($articleid, $newid, 'articlefeeds')
        or return undef;
    $self -> _change_article_relation($articleid, $newid, 'articleimages')
        or return undef;
    $self -> _change_article_relation($articleid, $newid, 'articlefiles')
        or return undef;
    $self -> _change_article_relation($articleid, $newid, 'articlelevels')
        or return undef;
    $self -> _change_article_relation($articleid, $newid, 'article_notify')
        or return undef;
    $self -> _change_article_relation($articleid, $newid, 'articlesection')
        or return undef;

    # Get here and the duplicate has been made, so remove the original
    my $remh = $self -> {"dbh"} -> prepare("DELETE FROM `".$self -> {"settings"} -> {"database"} -> {"articles"}."`
                                            WHERE id = ?");
    $rows = $remh -> execute($articleid);
    return $self -> self_error("Unable to perform article move cleanup: ". $self -> {"dbh"} -> errstr) if(!$rows);
    return $self -> self_error("Article move cleanup failed, no rows inserted") if($rows eq "0E0");

    return $newid;
}


# ============================================================================
#  Autosave support methods

## @method $ set_autosave($userid, $subject, $summary, $article)
# Set the autosave data for the specified user, overwriting any previously stored
# autosave or creating the autosave if the user does not already have one.
#
# @param userid  The ID of the user autosaving
# @param subject The subject to store.
# @param summary The summary to store.
# @param article The full article text to store.
# @return true on success, undef on error
sub set_autosave {
    my $self    = shift;
    my $userid  = shift;
    my $subject = shift;
    my $summary = shift;
    my $article = shift;

    $self -> clear_error();

    # Remove old autosaves
    $self -> _cleanup_autosave($userid)
        or return undef;

    # Deactivate previous autosaves
    $self -> clear_autosave($userid)
        or return undef;

    return $self -> _add_autosave($userid, $subject, $summary, $article);
}


## @method $ get_autosave($userid)
# Fetch the autosave data for the specified user, if the user has any set.
#
# @param userid  The ID of the user to fetch autosave data for.
# @return A reference to a hash containing the user's autosave data, or an
#         empty hash if the user has no autosave data; undef on error.
sub get_autosave {
    my $self   = shift;
    my $userid = shift;

    $self -> clear_error();

    my $geth = $self -> {"dbh"} -> prepare("SELECT *
                                            FROM `".$self -> {"settings"} -> {"database"} -> {"autosave"}."`
                                            WHERE `user_id` = ?
                                            AND `active` = 1
                                            LIMIT 1");
    $geth -> execute($userid)
        or return $self -> self_error("Unable to execute autosave lookup: ".$self -> {"dbh"} -> errstr);

    return ($geth -> fetchrow_hashref() || {});
}


## @method $ clear_autosave($userid)
# Delete the specified user's autosave data.
#
# @param userid  The ID of the user to delete the autosave for
# @return true on success, undef on error
sub clear_autosave {
    my $self   = shift;
    my $userid = shift;

    $self -> clear_error();

    my $nukeh = $self -> {"dbh"} -> prepare("UPDATE `".$self -> {"settings"} -> {"database"} -> {"autosave"}."`
                                             SET `active` = 0
                                             WHERE `user_id` = ?
                                             AND `active` = 1");
    $nukeh -> execute($userid)
        or return $self -> self_error("Unable to execute autosave archive: ".$self -> {"dbh"} -> errstr);

    return 1;
}


# ============================================================================
#  Private autosave support methods

## @method private $ _add_autosave($userid, $subject, $summary, $article)
# Create the autosave data for the specified user. This will fail if the user
# already has autosave data!
#
# @param userid  The ID of the user autosaving
# @param subject The subject to store.
# @param summary The summary to store.
# @param article The full article text to store.
# @return true on success, undef on error
sub _add_autosave {
    my $self    = shift;
    my $userid  = shift;
    my $subject = shift;
    my $summary = shift;
    my $article = shift;

    $self -> clear_error();

    # Add the new autosave
    my $newh = $self -> {"dbh"} -> prepare("INSERT INTO `".$self -> {"settings"} -> {"database"} -> {"autosave"}."`
                                            (`user_id`, `subject`, `summary`, `article`, `saved`)
                                            VALUES(?, ?, ?, ?, UNIX_TIMESTAMP())");
    my $rows = $newh -> execute($userid, $subject, $summary, $article);
    return $self -> self_error("Unable to perform autosave insert: ". $self -> {"dbh"} -> errstr) if(!$rows);
    return $self -> self_error("Autosave insert failed, no rows inserted") if($rows eq "0E0");

    return 1;
}


## @method private $ _cleanup_autosave($userid)
# Delete autosaves for the specified user that are older than the
# configured autosave age (or 2 weeks, if not set)
#
# @param userid The ID of the user to clean up autosaves for
# @return true on success, undef on error.
sub _cleanup_autosave {
    my $self   = shift;
    my $userid = shift;

    $self -> clear_error();

    my $threshold = time() - ($self -> {"settings"} -> {"config"} -> {"Article:autosave_age"} // 1209600);

    my $nukeh = $self -> {"dbh"} -> prepare("DELETE FROM `".$self -> {"settings"} -> {"database"} -> {"autosave"}."`
                                             WHERE `user_id` = ?
                                             AND `saved` < ?");
    $nukeh -> execute($userid, $threshold)
        or return $self -> self_error("Unable to perform autosave cleanup: ".$self -> {"dbh"} -> errstr);

    return 1;
}


# ==============================================================================
#  Private methods

## @method private $ _get_level_byname($name)
# Obtain the ID of the level with the specified name, if possible.
#
# @param name The name of the level to get the ID for
# @return the level ID on success, undef on failure
sub _get_level_byname {
    my $self  = shift;
    my $level = shift;

    my $levelh = $self -> {"dbh"} -> prepare("SELECT id FROM `".$self -> {"settings"} -> {"database"} -> {"levels"}."`
                                              WHERE `level` LIKE ?");
    $levelh -> execute($level)
        or return $self -> self_error("Unable to execute level lookup query: ".$self -> {"dbh"} -> errstr);

    my $levrow = $levelh -> fetchrow_arrayref()
        or return $self -> self_error("Request for non-existent level '$level', giving up");

    return $levrow -> [0];
}


## @method private $ _get_article_metadataid($articleid)
# Given an article ID, obtain the metadata context ID for the article.
#
# @param articleid The ID of the article to fetch the metadata for
# @return The metadata ID on success, undef on error.
sub _get_article_metadata {
    my $self      = shift;
    my $articleid = shift;

    my $metah = $self -> {"dbh"} -> prepare("SELECT `metadata_id`
                                             FROM `".$self -> {"settings"} -> {"database"} -> {"articles"}."`
                                             WHERE `id` = ?");
    $metah -> execute($articleid)
        or return $self -> self_error("Unable to execute article metadata lookup query: ".$self -> {"dbh"} -> errstr);

    my $meta = $metah -> fetchrow_arrayref()
        or return $self -> self_error("Request for non-existent article '$articleid', giving up");

    return $meta -> [0];
}


## @method private $ _create_article_metadata($previd, $feeds, $sectionid, $mode)
# Create a metadata context to attach to the article specified. This will determine
# whether the article can be attached to a single feed's metadata, whether it can
# be attached to a schedule's metadata, or whether it needs to be attached to the
# root.
#
# @param previd    The ID of the previous article
# @param feeds     A reference to an array of IDs for feeds the article has been posted in.
# @param sectionid The ID of the schedule section the article is being added to.
# @param mode      0 indicates the article is a normal article, 1 indicates it is a
#                  newsletter article.
# @return The new metadata context ID on success, undef otherwise.
sub _create_article_metadata {
    my $self      = shift;
    my $previd    = shift;
    my $feeds     = shift;
    my $sectionid = shift;
    my $mode      = shift;

    $self -> clear_error();

    # If a previous ID has been provided, try to hang off its metadata (this
    # should allow multiple edits to an article and retain access for non-admin
    # authors to their article)
    if($previd) {
        my $metadataid = $self -> _get_article_metadata($previd)
            or return undef;

        return $self -> {"metadata"} -> create($metadataid);
    }

    # Normal article with feeds available?
    if($mode == 0 && $feeds) {

        # A single feed allows the article to be added to that feed's tree.
        if(scalar(@{$feeds}) == 1) {
            my $feed = $self -> {"feed"} -> get_feed_byid($feeds -> [0])
                or return $self -> self_error($self -> {"feed"} -> errstr());

            return $self -> {"metadata"} -> create($feed -> {"metadata_id"});

            # Multiple feeds mean that the article can not be attached to any single feed's metadata
            # tree. Instead it has to descend from a defined context (probably the root).
        } else {
            return $self -> {"metadata"} -> create($self -> {"settings"} -> {"config"} -> {"Article:multifeed_context_parent"})
        }

    # Newsletter article with a section?
    } elsif($mode == 1 && $sectionid) {
        my $section = $self -> {"schedule"} -> get_section($sectionid)
            or return $self -> self_error($self -> {"schedule"} -> errstr());

        return $self -> {"metadata"} -> create($section -> {"metadata_id"});

    # Something gone wrong, fall back on the default
    } else {
        return $self -> {"metadata"} -> create($self -> {"settings"} -> {"config"} -> {"Article:multifeed_context_parent"});
    }
}


## @method private $ _add_level_relations($articleid, $levels)
# Add a relation between an article and or or more levels
#
# @param articleid The ID of the article to add the relation for.
# @param levels    A reference to a hash of enabled levels, keys are level names
#                  values are ignored.
# @return True on success, undef on error.
sub _add_level_relations {
    my $self      = shift;
    my $articleid = shift;
    my $levels    = shift;

    $self -> clear_error();

    my $newh = $self -> {"dbh"} -> prepare("INSERT INTO `".$self -> {"settings"} -> {"database"} -> {"articlelevels"}."`
                                            (`article_id`, `level_id`)
                                            VALUES(?, ?)");
    foreach my $level (keys(%{$levels})) {
        my $levelid = $self -> _get_level_byname($level)
            or return undef;

        my $rows = $newh -> execute($articleid, $levelid);
        return $self -> self_error("Unable to perform level relation insert: ". $self -> {"dbh"} -> errstr) if(!$rows);
        return $self -> self_error("Level relation insert failed, no rows inserted") if($rows eq "0E0");
    }

    return 1;
}


## @method private $ _clear_sticky()
# Clears all outdated sticky bits in the articles table. This must be called
# before any article list fetches happen, to ensure that sticky articles do
# not hang around longer than they should.
#
# @return true on success, undef on error
sub _clear_sticky {
    my $self = shift;

    $self -> clear_error();

    my $teflon = $self -> {"dbh"} -> prepare("UPDATE `".$self -> {"settings"} -> {"database"} -> {"articles"}."`
                                              SET is_sticky = 0
                                              WHERE is_sticky = 1
                                              AND sticky_until < UNIX_TIMESTAMP()");
    $teflon -> execute()
        or return $self -> self_error("Unable to clear outdated sticky articles: ".$self -> {"dbh"} -> errstr);

    return 1;
}


## @method private @ _build_articlelist_timebounds($year, $month, $day)
# Calculate the start and end timestamps to use when listing articles based
# on the year, month, and day specified. Note that the arguments allow for
# progressive levels of refinement and are optional from left to right: if
# a month is specified, a year must be, if a day is specified a month must
# be, but specifying a year does not require a month to be specified. The
# parameters provided also determine the size of the window: if only a year
# is provided, the start is the start of the year, and the end is the end of
# the year; if a month is provided the period is just that month, and so on.
#
# @param year  The year to return articles for. Must be a 4 digit year number.
# @param month The month in the year to fetch articles for, must be in the
#              range 1 to 12.
# @param day   The day to fetch articles for, should be in the range 1 to 31.
# @return The start and end unix timestamps if the specified dates are valid,
#         undefs otherwise.
sub _build_articlelist_timebounds {
    my $self = shift;
    my ($year, $month, $day) = @_;
    my $mode = "year";

    # Can't calculate any range if there's no year
    if(!$year) {
        return (undef, undef);

    # year but no month means a full year
    } elsif(!$month) {
        $month = $day = 1;

    # year and month mean a full month
    } elsif(!$day) {
        $day = 1;
        $mode = "month";

    # year, month, and day - just one day of results
    } else {
        $mode = "day";
    }

    # And now build start and end dates from the available data
    my ($start, $end);

    # The DateTime constructor will die if the parameters are invalid. While
    # the values should be fine, use fancy-wrapped eval to be sure.
    eval {
        given($mode) {
            when('year') {
                $start = DateTime -> new(year => $year, time_zone => "UTC");
                $end   = $start -> clone() -> add(years => 1, seconds => -1);
            }
            when('month') {
                $start = DateTime -> new(year => $year, month => $month, time_zone => "UTC");
            $end   = $start -> clone() -> add(months => 1, seconds => -1);
            }
            when('day') {
                $start = DateTime -> new(year => $year, month => $month, day => $day, time_zone => "UTC");
                $end   = $start -> clone() -> add(months => 1, seconds => -1);
            }
            default {
                return (undef, undef);
            }
        }

    # If the start/end creation dies for some reason, log it, but there's not
    # much else can be done that that
    };

    if($@){
        $self -> self_error("Error in DateTime operation: $@");
        return (undef, undef);
    }

    return ($start -> epoch(), $end -> epoch());
}


## @method private $ _article_user_match($article, $userlist)
# Given a list of user IDs, return true if the specified article was created or
# updated by a user in the list. If the specified list is list is undef, this
# always returns true.
#
# @param article  The article to check the users against.
# @param userlist A reference to a list of user IDs to accept.
# @return true if the article was created/edited by one of the users in the
#              list, false otherwise.
sub _article_user_match {
    my $self     = shift;
    my $article  = shift;
    my $userlist = shift;

    # Empty list is always a true
    return 1 if(!$userlist);

    # Convert to a hash for faster lookup
    my %userhash = map { $_ => $_ } @{$userlist};

    # If the creator or editor is in the userlist, return true
    return ($userhash{$article -> {"creator_id"}} ||
            $userhash{$article -> {"updated_id"}});
}


## @method private $ _article_feed_match($article, $feedlist)
# Given a list of feed IDs, return true if the specified article has been
# added to one or more of those feeds. If the specified feed list is undef
# or empty, this will always return true.
#
# @param article  The article to check feeds against.
# @param feedlist A reference to a list of feed IDs to accept.
# @return true if the article is in one of the specified feeds, false
#         otherwise.
sub _article_feed_match {
    my $self     = shift;
    my $article  = shift;
    my $feedlist = shift;

    # Get the simple check out of the way first
    return 1 if(!$feedlist);

    # Convert to a hash for faster lookup
    my %feedhash = map { $_ => $_ } @{$feedlist};

    # Now check through the list of feeds
    foreach my $feed (@{$article -> {"feeds"}}) {
        return 1 if($feedhash{$feed -> {"id"}});
    }

    return 0;
}


## @method private $ _article_level_match($article, $levellist)
# Given a list of level IDs, return true if the specified article has been
# posted at one or more of those levels. If the specified level list is undef
# or empty, this will always return true.
#
# @param article  The article to check levels against.
# @param levellist A reference to a list of level IDs to accept.
# @return true if the article has been posted at one of the specified levels,
#         false otherwise.
sub _article_level_match {
    my $self      = shift;
    my $article   = shift;
    my $levellist = shift;

    # Get the simple check out of the way first
    return 1 if(!$levellist);

    # Convert to a hash for faster lookup
    my %levelhash = map { $_ => $_ } @{$levellist};

    # Now check through the list of levels
    foreach my $level (@{$article -> {"levels"}}) {
        return 1 if($levelhash{$level -> {"id"}});
    }

    return 0;
}


## @method private $ _article_mode_control($modes, $params)
# Generate a list of modes to match in the article list SQL query.
#
# @param modes  A reference to a list of selected mode names.
# @param params A reference to the list of placeholder parameters.
# @return An empty string if no modes have been selected, otherwise
#         a string containing an SQL query fragment.
sub _article_mode_control {
    my $self   = shift;
    my $modes  = shift;
    my $params = shift;

    # Do nothing if no modes are set
    return "" if(!$modes || !scalar(@{$modes}));

    my @markers = ();
    foreach my $mode (@{$modes}) {
        push(@markers, '?');
        push(@{$params}, $mode);
    }

    return "`article`.`release_mode` IN (".join(",", @markers).")";
}


sub _get_article_section {
    my $self     = shift;
    my $article  = shift;
    my $digested = shift;

    $self -> clear_error();

    # First need to fetch the section ID information based on whether the article has been digested
    my $table = $digested ? $self -> {"settings"} -> {"database"} -> {"articledigest"}
                          : $self -> {"settings"} -> {"database"} -> {"articlesection"};

    my $secth = $self -> {"dbh"} -> prepare("SELECT * FROM `$table`
                                             WHERE `article_id` = ?");
    $secth -> execute($article -> {"id"})
        or return $self -> self_error("Unable to execute article section query for article '".$article -> {"id"}."': ".$self -> {"dbh"} -> errstr);

    my $section = $secth -> fetchrow_hashref()
        or return $self -> self_error("No section data specifeid for article ".$article -> {"id"});

    # If its digested, pull the digest information, and the base section/schedule
    if($digested) {
        #$article -> {"digest_section_data"} = $self -> {"schedule"} -> get_digest_section($section -> {"section_id"})
        #    or return $self -> self_error($self -> {"schedule"} -> errstr());

        $article -> {"section_data"} = $self -> {"schedule"} -> get_section($section -> {"section_id"})
            or return $self -> self_error($self -> {"schedule"} -> errstr());

    # Otherwise just pull the section/schedule.
    } else {
        $article -> {"section_data"} = $self -> {"schedule"} -> get_section($section -> {"section_id"})
            or return $self -> self_error($self -> {"schedule"} -> errstr());
    }

    # Copy out the IDs into a consistent format for edit
    $article -> {"section"}     = $article -> {"section_data"} -> {"id"};
    $article -> {"schedule"}    = $article -> {"section_data"} -> {"schedule"} -> {"name"};
    $article -> {"schedule_id"} = $article -> {"section_data"} -> {"schedule"} -> {"id"};
    $article -> {"sort_order"}  = $section -> {"sort_order"};

    return 1;
}


sub _change_article_relation {
    my $self = shift;
    my $oldid = shift;
    my $newid = shift;
    my $table = shift;

    $self -> clear_error();

    my $moveh = $self -> {"dbh"} -> prepare("UPDATE `".$self -> {"settings"} -> {"database"} -> {$table}."`
                                             SET `article_id` = ?
                                             WHERE `article_id` = ?");
    $moveh -> execute($newid, $oldid)
        or return $self -> self_error("Unable to perform '$table' relation update: ".$self -> {"dbh"} -> errstr);

    return 1;
}


sub _set_overide_flag {
    my $self     = shift;
    my $aid      = shift;
    my $override = shift;

    $self -> clear_error();

    my $overh = $self -> {"dbh"} -> prepare("UPDATE `".$self -> {"settings"} -> {"database"} -> {"articles"}."`
                                             SET `override_optout` = ?
                                             WHERE `id` = ?");
    $overh -> execute($override, $aid)
        or return $self -> self_error("Unable to set article override flag: ".$self -> {"dbh"} -> errstr);

    return 1;
}

1;
