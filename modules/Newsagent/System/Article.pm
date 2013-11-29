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
use base qw(Webperl::SystemModule); # This class extends the Newsagent block class
use v5.12;

use DateTime;
use DateTime::Event::Cron;
use File::Path qw(make_path);
use File::Copy;
use File::Type;
use Digest;
use Try::Tiny;
use Webperl::Utils qw(path_join hash_or_hashref);

# ============================================================================
#  Constructor

## @cmethod $ new(%args)
# Create a new Article object to manage tag allocation and lookup.
# The minimum values you need to provide are:
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

    # Allowed file types
    $self -> {"allowed_types"} = { "image/x-png" => "png",
                                   "image/jpeg"  => "jpg",
                                   "image/gif"   => "gif",
    };

    # Allowed sort fields
    $self -> {"allowed_fields"} = {"creator_id"   => "creator_id",
                                   "created"      => "created",
                                   "title"        => "title",
                                   "release_mode" => "release_mode",
                                   "release_time" => "release_time",
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
            $userlevels -> {$feed -> {"value"}} -> {$level -> {"value"}} = $capabilities -> {$level -> {"capability"}} || 0;
        }
    }

    return $userlevels;
}


## @method $ get_user_feeds($userid)
# Obtain the list of feeds the user has permission to post from. This
# checks through the list of available feeds, and determines whether
# the user is able to post messages from that feed before adding it to
# the list of feeds available to the user.
#
# @param userid The ID of the user requesting the feed list.
# @param levels A reference to an array of levels, as returned by get_all_levels()
# @return A reference to an array of hashrefs. Each hashref contains a feed
#         available to the user as a pair of key/value pairs.
sub get_user_feeds {
    my $self   = shift;
    my $userid = shift;
    my $levels = shift;

    $self -> clear_error();

    my $feedsh = $self -> {"dbh"} -> prepare("SELECT * FROM `".$self -> {"settings"} -> {"database"} -> {"feeds"}."`
                                              ORDER BY `description`");
    $feedsh -> execute()
        or return $self -> self_error("Unable to execute user feeds query: ".$self -> {"dbh"} -> errstr);

    my @feedlist = ();
    while(my $feed = $feedsh -> fetchrow_hashref()) {
        foreach my $level (@{$levels}) {
            if($self -> {"roles"} -> user_has_capability($feed -> {"metadata_id"}, $userid, $level -> {"capability"})) {
                push(@feedlist, {"name"       => $feed -> {"description"},
                                 "value"      => $feed -> {"name"},
                                 "id"         => $feed -> {"id"},
                                 "metadataid" => $feed -> {"metadata_id"}});
                last;
            }
        }
    }

    return \@feedlist;
}


## @method $ get_user_schedule_sections($userid)
# Fetch a list of the shedules and schedule sections the user has access to
# post messages in. This goes through the scheduled release settings and
# the sections for the same, and generates a hash containing the lists of
# each that the user can post to.
#
# @param userid The ID of the user to get the schedules and sections for.
# @return A reference to a hash containing the schedule and section data on
#         success, undef on error.
sub get_user_schedule_sections {
    my $self   = shift;
    my $userid = shift;

    $self -> clear_error();

    # What we're /actually/ interested in here is which sections the user
    # can post message to, the schedules they can post to come along as a
    # resuslt of that information. So we need to traverse the list of sections
    # recording which ones the user has permission to post to, and then
    # pull in the data for the schedules later as a side-effect.

    my $sectionh = $self -> {"dbh"} -> prepare("SELECT sec.id, sec.metadata_id, sec.name, sec.schedule_id, sch.name AS schedule_name, sch.schedule
                                                FROM ".$self -> {"settings"} -> {"database"} -> {"schedule_sections"}." AS sec,
                                                     ".$self -> {"settings"} -> {"database"} -> {"schedules"}." AS sch
                                                WHERE sch.id = sec.schedule_id
                                                ORDER BY sch.name, sec.sort_order");
    $sectionh -> execute()
        or return $self -> self_error("Unable to execute section lookup query: ".$self -> {"dbh"} -> errstr);

    my $result = {};
    while(my $section = $sectionh -> fetchrow_hashref()) {
        if($self -> {"roles"} -> user_has_capability($section -> {"metadata_id"}, $userid, "schedule")) {
            # Store the section name and id.
            push(@{$result -> {"id_".$section -> {"schedule_id"}} -> {"sections"}},
                 {"value" => $section -> {"id"},
                  "name"  => $section -> {"name"}});

            # And set the schedule fields if needed.
            if(!$result -> {"id_".$section -> {"schedule_id"}} -> {"schedule_name"}) {
                $result -> {"id_".$section -> {"schedule_id"}} -> {"schedule_name"} = $section -> {"schedule_name"};

                # Work out when the next two runs of the schedule are
                my $cron = DateTime::Event::Cron -> new($section -> {"schedule"});
                my $next_time = undef;
                for(my $i = 0; $i < 2; ++$i) {
                    $next_time = $cron -> next($next_time);
                    push(@{$result -> {"id_".$section -> {"schedule_id"}} -> {"next_run"}}, $next_time -> epoch);
                }

                # And store the cron for later user in the view
                $result -> {"id_".$section -> {"schedule_id"}} -> {"schedule"} = $section -> {"schedule"};
            }
        }
    }

    foreach my $id (sort(keys(%{$result}))) {
        push(@{$result -> {"_schedules"}}, {"value" => substr($id, 3),
                                            "name"  => $result -> {$id} -> {"schedule_name"}});
    }

    return $result;
}


## @method $ get_file_images()
# Obtain a list of all images currently stored in the system. This generates
# a list of images suitable for presenting the user with a dropdown from
# which they can select an already uploaded image file.
#
# @return A reference to an array of hashrefs to image data.
sub get_file_images {
    my $self = shift;

    $self -> clear_error();

    my $imgh = $self -> {"dbh"} -> prepare("SELECT id, name, location
                                            FROM `".$self -> {"settings"} -> {"database"} -> {"images"}."`
                                            WHERE `type` = 'file'
                                            ORDER BY `name`");
    $imgh -> execute()
        or return $self -> self_error("Unable to execute image list query: ".$self -> {"dbh"} -> errstr);

    my @imagelist;
    while(my $image = $imgh -> fetchrow_hashref()) {
        # NOTE: no need to do permission checks here - all users have access to
        # all images (as there's bugger all the system can do to prevent it)
        push(@imagelist, {"name"  => $image -> {"name"},
                          "title" => path_join($self -> {"settings"} -> {"config"} -> {"Article:upload_image_url"}, $image -> {"location"}),
                          "value" => $image -> {"id"}});
    }

    return \@imagelist;
}


## @method $ get_image_info($id)
# Obtain the storage information for the image with the specified id.
#
# @param id The ID of the image to fetch the information for.
# @return A reference to the image data on success, undef on error.
sub get_image_info {
    my $self = shift;
    my $id   = shift;

    $self -> clear_error();

    my $imgh = $self -> {"dbh"} -> prepare("SELECT *
                                            FROM `".$self -> {"settings"} -> {"database"} -> {"images"}."`
                                            WHERE `id` = ?");
    $imgh -> execute($id)
        or return $self -> self_error("Unable to execute image lookup: ".$self -> {"dbh"} -> errstr);

    return $imgh -> fetchrow_hashref();
}


## @method $ get_feed_articles($settings)
# Obtain the details of artibles from the database. This will search the database
# using the specified parameters, and return a reference to an array of records
# containing matching data. The following settings may be specified in the settings
# argument:
#
# - `id`: obtain the article with the specified ID. Note that, even though this will
#   only ever match at most one record, the returned value is still a reference to an
#   array of hashrefs.
# - `level`: obtain articles that are visible at the named level. Note that this is
#   the *name* of the level, not the level id, for readability. Valid levels are
#   defined in the `levels` table. Unknown/invalid levels will produce no matches.
#   If no level is specified, all levels are matched.
# - `feed`: obtain articles published by the specified feed or group. This is the
#   feed name, not the feed ID, and valid feeds are defined in the `feeds` table.
#   If no feed is specified, all feeds with messages at the current level are matched.
# - `count`: how many articles to return. If not specified, this defaults to the
#   system-wide setting defined in `Feed:count` in the settings table.
# - `offset`: article offset, first returned article is at offset 0.
# - `fulltext_mode`: if specified, the full article text will be included in the result,
#   otherwise only the title and summary will be included.
#
# @note This function will never return articles stored as `draft`, articles set
#       for timed release before the release time, or old revisions of articles.
#       It is purely intended to support feed generation - where none of the
#       aforementioned articles should ever be visible.
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

    # And work out what the level for the feed url should be
    my $urllevel = $settings -> {"urllevel"};
    $urllevel = $self -> {"settings"} -> {"config"} -> {"Feed:default_level"}
    if(!$urllevel);

    # convert to a feed id for a simpler query
    $urllevel = $self -> _get_level_byname($urllevel)
        or return undef;

    # Clear outdated sticky values
    $self -> _clear_sticky()
        or return undef;

    # Now start constructing the query. These are the tables and where clauses that are
    # needed regardless of the settings provided by the caller.
    # All the fields the query is interested in, normally fulltext is omitted unless explicitly requested
    my $fields = "`article`.`id`, `user`.`user_id` AS `userid`, `user`.`username` AS `username`, `user`.`realname` AS `realname`, `user`.`email`, `article`.`created`, `feed`.`name` AS `feedname`, `feed`.`default_url` AS `defaulturl`, `article`.`title`, `article`.`summary`, `article`.`release_time`, `urls`.`url` AS `feedurl`";
    $fields   .= ", `article`.`article` AS `fulltext`" if($settings -> {"fulltext_mode"});

    my $from  = "`".$self -> {"settings"} -> {"database"} -> {"articles"}."` AS `article`
                 LEFT JOIN `".$self -> {"settings"} -> {"database"} -> {"users"}."` AS `user`
                     ON `user`.`user_id` = `article`.`creator_id`
                 LEFT JOIN `".$self -> {"settings"} -> {"database"} -> {"feeds"}."` AS `feed`
                     ON `feed`.`id` = `article`.`feed_id`
                 LEFT JOIN `".$self -> {"settings"} -> {"database"} -> {"feedurls"}."` AS `urls`
                     ON (`urls`.`feed_id` = `article`.`feed_id` AND `urls`.`level_id` = ?)";
    my $where = "(`article`.`release_mode` = 'visible'
                   OR (`article`.`release_mode` = 'timed'
                        AND `article`.`release_time` <= UNIX_TIMESTAMP()
                      )
                 )";
    push(@params, $urllevel);   # argument for urls.level_id = ?

    # The next lot are extensions to the above to support filters requested by the caller.
    if($settings -> {"id"}) {
        $where .= " AND `article`.`id` = ?";
        push(@params, $settings -> {"id"});
    }

    # There can be multiple, comma separated feeds specified in the settings, so split them
    # and create an OR clause for the lot
    if($settings -> {"feed"}) {
        my @feeds = split(/,/, $settings -> {"feed"});
        my $feedfrag = "";

        foreach my $feed (@feeds) {
            $feedfrag .= " OR " if($feedfrag);
            $feedfrag .= "`feed`.`name` LIKE ?";
            push(@params, $feed);
        }
        $where .= " AND ($feedfrag)";
    }

    # Level filtering is a bit trickier, as it needs to do more joining, and has to deal with
    # comma separated values, to
    if($settings -> {"level"}) {
        my @levels = split(/,/, $settings -> {"level"});
        my $levelfrag = "";

        foreach my $level (@levels) {
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
        $where .= " AND `article`.`release_time` > ?";
        push(@params, $settings -> {"maxage"});
    }

    my $sql = "SELECT $fields
               FROM $from
               WHERE $where
               ORDER BY `article`.`is_sticky` DESC, `article`.`release_time` DESC
               LIMIT ".$settings -> {"offset"}.", ".$settings -> {"count"};

    # Now put it all together and fire it at the database
    my $query = $self -> {"dbh"} -> prepare($sql);
    $query -> execute(@params)
        or return $self -> self_error("Unable to execute article query: ".$self -> {"dbh"} -> errstr);

    # Fetch all the matching articles, and if there are any go and shove in the level list and images
    my $articles = $query -> fetchall_arrayref({});
    if(scalar(@{$articles})) {
        my $levelh = $self -> {"dbh"} -> prepare("SELECT `level`.`level`
                                                  FROM `".$self -> {"settings"} -> {"database"} -> {"levels"}."` AS `level`,
                                                       `".$self -> {"settings"} -> {"database"} -> {"articlelevels"}."` AS `artlevels`
                                                  WHERE `level`.`id` = `artlevels`.`level_id`
                                                  AND `artlevels`.`article_id` = ?");

        my $imageh = $self -> {"dbh"} -> prepare("SELECT `image`.*, `artimgs`.`order`
                                                  FROM `".$self -> {"settings"} -> {"database"} -> {"images"}."` AS `image`,
                                                       `".$self -> {"settings"} -> {"database"} -> {"articleimages"}."` AS `artimgs`
                                                  WHERE `image`.`id` = `artimgs`.`image_id`
                                                  AND `artimgs`.`article_id` = ?
                                                  ORDER BY `artimgs`.`order`");

        foreach my $article (@{$articles}) {
            $levelh -> execute($article -> {"id"})
                or return $self -> self_error("Unable to execute article level query for article '".$article -> {"id"}."': ".$self -> {"dbh"} -> errstr);

            # Need to copy the mode to each article.
            $article -> {"fulltext_mode"} = $settings -> {"fulltext_mode"};

            $article -> {"levels"} = $levelh -> fetchall_arrayref({});

            $imageh -> execute($article -> {"id"})
                or return $self -> self_error("Unable to execute article image query for article '".$article -> {"id"}."': ".$self -> {"dbh"} -> errstr);

            $article -> {"images"} = [];
            # Place the images into the images array based using the order as the array position
            while(my $image = $imageh -> fetchrow_hashref()) {
                $article -> {"images"} -> [$image -> {"order"}] = $image;
            }
        }
    } # if(scalar(@{$articles})) {

    return $articles;
}


## @method @ get_user_articles($userid, $settings)
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
#
#
# @param userid    The ID of the user requesting the article list.
# @return A reference to an array of articles the user can edit, and a count of the
#         number of articles the user can edit (which may be larger than the size
#         of the returned array, if `count` is specified.
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

    my $fields = "`article`.*, `user`.`user_id` AS `userid`, `user`.`username` AS `username`, `user`.`realname` AS `realname`, `user`.`email`, `feed`.`name` AS `feedname`, `feed`.`description` AS `feeddesc`";
    my $from   = "`".$self -> {"settings"} -> {"database"} -> {"articles"}."` AS `article`
                  LEFT JOIN `".$self -> {"settings"} -> {"database"} -> {"users"}."` AS `user`
                      ON `user`.`user_id` = `article`.`creator_id`
                  LEFT JOIN `".$self -> {"settings"} -> {"database"} -> {"feeds"}."` AS `feed`
                      ON `feed`.`id` = `article`.`feed_id`";
    my $where  = $settings -> {"hidedeleted"} ? " WHERE `article`.`release_mode` != 'deleted'" : "";
    my @params;

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
    $articleh -> execute(@params)
        or return $self -> self_error("Unable to execute article query: ".$self -> {"dbh"} -> errstr);

    # FIXME: as more and more articles are added to the system, this process is going to become
    #        slower and slower. There may need to be some form of hard time-based filtering done
    #        on articles. For example, users may need to specify a month and year to fetch articles
    #        for, and that will allow constraining of data.
    my ($added, $count, $feeds) = (0, 0, {});
    while(my $article = $articleh -> fetchrow_hashref()) {
        # Does the user have edit access to this article?
        if($self -> {"roles"} -> user_has_capability($article -> {"metadata_id"}, $userid, "edit")) {
            # If an offset has been specified, have enough articles been skipped, and if
            # a count has been specified, is there still space for more entries?
            if((!$settings -> {"offset"} || $count >= $settings -> {"offset"}) &&
               (!$settings -> {"count"}  || $added < $settings -> {"count"})) {

                # Yes, fetch the level information for the article
                $levelh -> execute($article -> {"id"})
                    or return $self -> self_error("Unable to execute article level query for article '".$article -> {"id"}."': ".$self -> {"dbh"} -> errstr);

                $article -> {"levels"} = $levelh -> fetchall_arrayref({});

                # And store it
                push(@articles, $article);
                ++$added; # keep a separate 'added' counter, it may be faster than scalar()
            }

            # Regardless of whether this article has been included in the list, we need
            # to record its feed as a feed the user has access to
            # FIXME: This will need modifying when multi-feed articles are supported
            $feeds -> {$article -> {"feedname"}} = $article -> {"feeddesc"}
                if(!$feeds -> {$article -> {"feedname"}});

            ++$count;
        }
    }

    return (\@articles, $count, $feeds);
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

    my $fields = "`article`.*, `user`.`user_id` AS `userid`, `user`.`username` AS `username`, `user`.`realname` AS `realname`, `user`.`email`, `feed`.`name` AS `feedname`, `feed`.`description` AS `feeddesc`";
    my $from   = "`".$self -> {"settings"} -> {"database"} -> {"articles"}."` AS `article`
                  LEFT JOIN `".$self -> {"settings"} -> {"database"} -> {"users"}."` AS `user`
                      ON `user`.`user_id` = `article`.`creator_id`
                  LEFT JOIN `".$self -> {"settings"} -> {"database"} -> {"feeds"}."` AS `feed`
                      ON `feed`.`id` = `article`.`feed_id`";

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

    my $imageh = $self -> {"dbh"} -> prepare("SELECT `image`.*, `artimgs`.`order`
                                              FROM `".$self -> {"settings"} -> {"database"} -> {"images"}."` AS `image`,
                                                   `".$self -> {"settings"} -> {"database"} -> {"articleimages"}."` AS `artimgs`
                                              WHERE `image`.`id` = `artimgs`.`image_id`
                                              AND `artimgs`.`article_id` = ?
                                              ORDER BY `artimgs`.`order`");
    $articleh -> execute($articleid)
        or return $self -> self_error("Unable to execute article query: ".$self -> {"dbh"} -> errstr);

    my $article = $articleh -> fetchrow_hashref()
        or return $self -> self_error("Request for non-existent article with ID $articleid");

    $levelh -> execute($article -> {"id"})
        or return $self -> self_error("Unable to execute article level query for article '".$article -> {"id"}."': ".$self -> {"dbh"} -> errstr);

    $article -> {"levels"} = $levelh -> fetchall_arrayref({});

    $imageh -> execute($article -> {"id"})
        or return $self -> self_error("Unable to execute article image query for article '".$article -> {"id"}."': ".$self -> {"dbh"} -> errstr);

    my $images = $imageh -> fetchall_arrayref({});
    foreach my $image (@{$images}) {
        $article -> {"images"} -> [$image -> {"order"}] = $image;
    }

    return $article;
}


# ==============================================================================
#  Storage and addition functions

## @method $ store_image($srcfile, $filename, $userid)
# Given a source filename and a userid, move the file into the image filestore
# (if needed) and then return the information needed to attach to an article.
#
# @param srcfile  The absolute path to the source file to obtain a path for.
# @param filename The name of the file to write the source file to, without any path.
# @param userid   The ID of the user saving the file
# @return A reference to the image storage data hash on success, undef on error.
sub store_image {
    my $self     = shift;
    my $srcfile  = shift;
    my $filename = shift;
    my $userid   = shift;
    my $digest;

    $self -> clear_error();

    # Determine whether the file is allowed
    my $filetype = File::Type -> new();
    my $type = $filetype -> mime_type($srcfile);

    my @types = sort(values(%{$self -> {"allowed_types"}}));
    return $self -> self_error("$filename is not a supported image format. Permitted formats are: ".join(", ", @types))
        unless($type && $self -> {"allowed_types"} -> {$type});

    # Now, calculate the md5 of the file so that duplicate checks can be performed
    open(IMG, $srcfile)
        or return $self -> self_error("Unable to open uploaded file '$srcfile': $!");
    binmode(IMG); # probably redundant, but hey

    eval {
        $digest = Digest -> new("MD5");
        $digest -> addfile(*IMG);

        close(IMG);
    };
    return $self -> self_error("An error occurred while processing '$filename': $@")
        if($@);

    my $md5 = $digest -> hexdigest;

    # Determine whether a file already exists with the current md5. IF it does,
    # return the information for the existing file rather than making a new copy.
    my $exists = $self -> _file_md5_lookup($md5);
    if($exists || $self -> errstr()) {
        # Log the duplicate hit if appropriate.
        $self -> {"logger"} -> log('notice', $userid, undef, "Request to store image $filename, already exists as image ".$exists -> {"id"})
            if($exists);

        return $exists;
    }

    # File does not appear to be a duplicate, so moving it into the tree should be okay.
    # The first stage of this is to obtain a new file record ID to use as a unique
    # directory name.
    my $newid = $self -> _add_file($filename, $md5)
        or return undef;

    # Convert the id to a destination directory
    if(my $outdir = $self -> _build_destdir($newid)) {
        # Now build the paths needed for moving things
        my $outname = path_join($outdir, $filename);
        my $outpath = path_join($self -> {"settings"} -> {"config"} -> {"Article:upload_image_path"}, $outname);

        my ($cleanout) = $outpath =~ m|^((?:/[-\w.]+)+?(?:\.\w+)?)$|;

        if(copy($srcfile, $cleanout)) {
            if($self -> _update_location($newid, $outname)) {
                $self -> {"logger"} -> log('notice', $userid, undef, "Stored image $filename in $outname, image id $newid");

                return $self -> get_image_info($newid);
            }
        } else {
            $self -> self_error("Unable to copy image file $filename: $!");
        }
    }

    # Get here and something broke, save the error and clean up before returning it
    my $errstr = $self -> errstr();
    $self -> {"logger"} -> log('error', $userid, undef, "Unable to store image $filename: $errstr");

    $self -> _delete_image($newid);
    return $self -> self_error($errstr);
}


## @method $ add_article($article, $userid, $previd)
# Add an article to the system's database. This function adds an article to the system
# using the contents of the specified hash to fill in the article fields in the db.
#
# @param article A reference to a hash containing article data, as generated by the
#                _validate_article_fields() function.
# @param userid  The ID of the user creating this article.
# @oaram previd  The ID of a previous revision of the article.
# @return The ID of the new article on success, undef on error.
sub add_article {
    my $self    = shift;
    my $article = shift;
    my $userid  = shift;
    my $previd  = shift;

    $self -> clear_error();

    # resolve the feed
    my $feed = $self -> _get_feed_byname($article -> {"feed"})
        or return undef;

    # Add urls to the database
    foreach my $id (keys(%{$article -> {"images"}})) {
        if($article -> {"images"} -> {$id} -> {"mode"} eq "url") {
            $article -> {"images"} -> {$id} -> {"img"} = $self -> _add_url($article -> {"images"} -> {$id} -> {"url"})
                or return undef;
        }
    }

    # Make a new metadata context to attach to the article
    my $metadataid = $self -> {"metadata"} -> create($feed -> {"metadata_id"})
        or return $self -> self_error("Unable to create new metadata context: ".$self -> {"metadata"} -> errstr());

    # Fix up release time
    my $now = time();
    $article -> {"rtimestamp"} = $now if(!$article -> {"rtimestamp"});

    my ($is_sticky, $sticky_until) = (0, undef);
    if($article -> {"sticky"}) {
        $is_sticky = 1;
        $sticky_until = $article -> {"rtimestamp"} + ($article -> {"sticky"} * 86400)
    }

    # Add the article itself
    my $addh = $self -> {"dbh"} -> prepare("INSERT INTO `".$self -> {"settings"} -> {"database"} -> {"articles"}."`
                                            (previous_id, metadata_id, creator_id, created, feed_id, title, summary, article, preset, release_mode, release_time, updated, updated_id, sticky_until, is_sticky)
                                            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)");
    my $rows = $addh -> execute($previd, $metadataid, $userid, $now, $feed -> {"id"}, $article -> {"title"}, $article -> {"summary"}, $article -> {"article"}, $article -> {"preset"}, $article -> {"mode"}, $article -> {"rtimestamp"}, $now, $userid, $sticky_until, $is_sticky);
    return $self -> self_error("Unable to perform article insert: ". $self -> {"dbh"} -> errstr) if(!$rows);
    return $self -> self_error("Article insert failed, no rows inserted") if($rows eq "0E0");

    # FIXME: This ties to MySQL, but is more reliable that last_insert_id in general.
    #        Try to find a decent solution for this mess...
    # NOTE: the DBD::mysql documentation doesn't actually provide any useful information
    #       about what this will contain if the insert fails. In fact, DBD::mysql calls
    #       libmysql's mysql_insert_id(), which returns 0 on error (last insert failed).
    #       There, why couldn't they bloody /say/ that?!
    my $newid = $self -> {"dbh"} -> {"mysql_insertid"};

    return $self -> self_error("Unable to obtain id for new article row")
        if(!$newid);

    # Now set up image and level associations
    $self -> _add_image_relation($newid, $article -> {"images"} -> {"a"} -> {"img"}, 0) or return undef
        if($article -> {"images"} -> {"a"} -> {"img"});

    $self -> _add_image_relation($newid, $article -> {"images"} -> {"b"} -> {"img"}, 1) or return undef
        if($article -> {"images"} -> {"b"} -> {"img"});

    foreach my $level (keys(%{$article -> {"levels"}})) {
        $self -> _add_level_relation($newid, $level)
            or return undef;
    }

    # Attach to the metadata context
    $self -> {"metadata"} -> attach($metadataid)
        or return $self -> self_error("Error in metadata system: ".$self -> {"metadata"} -> errstr());

    # Give the user editor access to the article
    my $roleid = $self -> {"roles"} -> role_get_roleid("editor");
    $self -> {"roles"} -> user_assign_role($metadataid, $userid, $roleid)
        or return $self -> self_error($self -> {"roles"} -> errstr());

    return $newid;
}


## @method $ set_article_status($articleid, $userid, $newmode, $setdate)
# Update the release mode for the specified article. This will update the mode
# set for the article and change its `updated` timestamp, it may also modify
# the release time timestamp if required.
#
# @param articleid The ID of the article to update.
# @param userid    The ID of the user updating the article.
# @param newmode   The new mode to set for the article.
# @param setdate   Update the release_time to the current time.
# @return A reference to a hash containing the updated article data on success,
#         undef on error.
sub set_article_status {
    my $self      = shift;
    my $articleid = shift;
    my $userid    = shift;
    my $newmode   = shift;
    my $setdate   = shift;

    my $updateh = $self -> {"dbh"} -> prepare("UPDATE `".$self -> {"settings"} -> {"database"} -> {"articles"}."`
                                               SET `updated` = UNIX_TIMESTAMP(), `updated_id` = ?, `release_mode` = ?".($setdate ? ", `release_time` = UNIX_TIMESTAMP()" : "")."
                                               WHERE id = ?");
    my $result = $updateh -> execute($userid, $newmode, $articleid);
    return $self -> self_error("Unable to update article mode: ".$self -> {"dbh"} -> errstr) if(!$result);
    return $self -> self_error("Article mode update failed: no rows updated.") if($result eq "0E0");

    return $self -> get_article($articleid);
}


# ==============================================================================
#  Private methods

## @method private $ _build_destdir($id)
# Given a file id, determine which directory the corresponding file should be stored
# in, and ensure that the directory tree is in place for it. Note that this will
# create a hierarchy of directories, up to 100 directories (00 to 99) at the top
# level, and with up to 100 directories (again, 0 to 99) in each of the top-level
# directories. This is to reduce the number of files and directories present in
# any single directory to help out filesystems that struggle with lots of either.
#
# @param id The ID of the file to store.
# @return A path to store the file in, relative to Article:upload_image_path, on success.
#         undef on error.
sub _build_destdir {
    my $self = shift;
    my $id   = shift;

    $self -> clear_error();

    # Pad the id with zeros out to at least 4 characters
    my $pad    = 4 - length($id);
    my $padded = $pad > 0 ? ("0" x $pad).$id : $id;

    # Now pull out the bits, and rejoin them into the required form
    my ($base, $sub) = $padded =~ /^(\d\d)(\d\d)/;
    my $destdir = path_join($base, $sub, $id);

    # Make sure the path exists
    my $fullpath = path_join($self -> {"settings"} -> {"config"} -> {"Article:upload_image_path"}, $destdir);
    eval { make_path($fullpath); };
    return $self -> self_error("Unable to create image store directory: $@")
        if($@);

    return $destdir;
}


## @method private $ _file_md5_lookup($md5)
# Look up a file based on the provided md5. Why use MD5 rather than a more secure hash
# like SHA-256? Primarily as a result of speed (md5 is usually 30% faster), but also
# because getting duplicate files is really not the end of the world, this is here
# as a simple check to prevent egregious duplication of uploads by end users, rather
# than as a vital bastion against the many-angled ones that live at the bottom of the
# Mandelbrot set.
#
# @param md5 The hex-encoded MD5 digest to search for
# @return A reference to an image record hash on success, undef if the md5 does
#         not exist, or on error.
sub _file_md5_lookup {
    my $self = shift;
    my $md5  = shift;

    $self -> clear_error();

    # Does the md5 match an already present image?
    my $md5h = $self -> {"dbh"} -> prepare("SELECT *
                                            FROM `".$self -> {"settings"} -> {"database"} -> {"images"}."`
                                            WHERE `md5` LIKE ?");
    $md5h -> execute($md5)
        or return $self -> self_error("Unable to perform image md5 search: ".$self -> {"dbh"} -> errstr);

    return $md5h -> fetchrow_hashref();
}


## @method private $ _add_file($name, $md5)
# Add an entry for a file to the images table.
#
# @param name The name of the image file to add.
# @param md5  The md5 of the image file being added.
# @return The id of the new image file row on success, undef on error.
sub _add_file {
    my $self = shift;
    my $name = shift;
    my $md5  = shift;

    $self -> clear_error();

    my $newh = $self -> {"dbh"} -> prepare("INSERT INTO `".$self -> {"settings"} -> {"database"} -> {"images"}."`
                                            (type, md5, name)
                                            VALUES('file', ?, ?)");
    my $rows = $newh -> execute($md5, $name);
    return $self -> self_error("Unable to perform image file insert: ". $self -> {"dbh"} -> errstr) if(!$rows);
    return $self -> self_error("Image file insert failed, no rows inserted") if($rows eq "0E0");

    # FIXME: This ties to MySQL, but is more reliable that last_insert_id in general.
    #        Try to find a decent solution for this mess...
    # NOTE: the DBD::mysql documentation doesn't actually provide any useful information
    #       about what this will contain if the insert fails. In fact, DBD::mysql calls
    #       libmysql's mysql_insert_id(), which returns 0 on error (last insert failed).
    #       There, why couldn't they bloody /say/ that?!
    my $newid = $self -> {"dbh"} -> {"mysql_insertid"};

    return $self -> self_error("Unable to obtain id for new image file row")
        if(!$newid);

    return $newid;
}


## @method private $ _add_url($url)
# Add an entry for a url to the images table.
#
# @param url The url of the image link to add.
# @return The id of the new image file row on success, undef on error.
sub _add_url {
    my $self = shift;
    my $url  = shift;

    $self -> clear_error();

    # Work out the name
    my ($name) = $url =~ m|/([^/]+?)(\?.*)?$|;
    $name = "unknown" if(!$name);

    my $newh = $self -> {"dbh"} -> prepare("INSERT INTO `".$self -> {"settings"} -> {"database"} -> {"images"}."`
                                            (type, name, location)
                                            VALUES('url', ?, ?)");
    my $rows = $newh -> execute($name, $url);
    return $self -> self_error("Unable to perform image url insert: ". $self -> {"dbh"} -> errstr) if(!$rows);
    return $self -> self_error("Image url insert failed, no rows inserted") if($rows eq "0E0");

    # FIXME: This ties to MySQL, but is more reliable that last_insert_id in general.
    #        Try to find a decent solution for this mess...
    # NOTE: the DBD::mysql documentation doesn't actually provide any useful information
    #       about what this will contain if the insert fails. In fact, DBD::mysql calls
    #       libmysql's mysql_insert_id(), which returns 0 on error (last insert failed).
    #       There, why couldn't they bloody /say/ that?!
    my $newid = $self -> {"dbh"} -> {"mysql_insertid"};

    return $self -> self_error("Unable to obtain id for new image url row")
        if(!$newid);

    return $newid;
}


## @method private $ _delete_image($id)
# Remove the file entry for the specified row. This is primarily needed to
# clean up partial file entries that are created during store_image() if that
# function fails to copy the image into place.
#
# @param id The ID of the image row to remove.
# @return true on success, undef on error.
sub _delete_image {
    my $self = shift;
    my $id   = shift;

    $self -> clear_error();

    my $nukeh = $self -> {"dbh"} -> prepare("DELETE FROM `".$self -> {"settings"} -> {"database"} -> {"image"}."`
                                             WHERE id = ?");
    $nukeh -> execute($id)
        or return $self -> self_error("Image delete failed: ".$self -> {"dbh"} -> errstr);

    return 1;
}


## @method private $ _update_location($id, $location)
# Update the image location for the specified image.
#
# @param id       The ID of the image to update the location for.
# @param location The location to set for the image.
# @return true on success, undef on error.
sub _update_location {
    my $self     = shift;
    my $id       = shift;
    my $location = shift;

    $self -> clear_error();

    my $updateh = $self -> {"dbh"} -> prepare("UPDATE `".$self -> {"settings"} -> {"database"} -> {"images"}."`
                                               SET `location` = ?
                                               WHERE `id` = ?");
    my $result = $updateh -> execute($location, $id);
    return $self -> self_error("Unable to update file location: ".$self -> {"dbh"} -> errstr) if(!$result);
    return $self -> self_error("File location update failed: no rows updated.") if($result eq "0E0");

    return 1;
}


## @method private $ _add_image_relation($articleid, $imageid, $order)
# Add a relation between an article and an image
#
# @param articleid The ID of the article to add the relation for.
# @param imageid   The ID of the image to add the relation to.
# @param order     The order of the relation. The first imge should be 1, second 2, and so on.
# @return The id of the new image association row on success, undef on error.
sub _add_image_relation {
    my $self      = shift;
    my $articleid = shift;
    my $imageid   = shift;
    my $order     = shift;

    $self -> clear_error();

    my $newh = $self -> {"dbh"} -> prepare("INSERT INTO `".$self -> {"settings"} -> {"database"} -> {"articleimages"}."`
                                            (`article_id`, `image_id`, `order`)
                                            VALUES(?, ?, ?)");
    my $rows = $newh -> execute($articleid, $imageid, $order);
    return $self -> self_error("Unable to perform image relation insert: ". $self -> {"dbh"} -> errstr) if(!$rows);
    return $self -> self_error("Image relation insert failed, no rows inserted") if($rows eq "0E0");

    # FIXME: This ties to MySQL, but is more reliable that last_insert_id in general.
    #        Try to find a decent solution for this mess...
    # NOTE: the DBD::mysql documentation doesn't actually provide any useful information
    #       about what this will contain if the insert fails. In fact, DBD::mysql calls
    #       libmysql's mysql_insert_id(), which returns 0 on error (last insert failed).
    #       There, why couldn't they bloody /say/ that?!
    my $newid = $self -> {"dbh"} -> {"mysql_insertid"};

    return $self -> self_error("Unable to obtain id for new image relation row")
        if(!$newid);

    return $newid;
}


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


## @method private $ _add_level_relation($articleid, $level)
# Add a relation between an article and a level
#
# @param articleid The ID of the article to add the relation for.
# @param level     The title (NOT the ID!) of the level to add the relation to.
# @return The id of the new level association row on success, undef on error.
sub _add_level_relation {
    my $self      = shift;
    my $articleid = shift;
    my $level     = shift;

    $self -> clear_error();

    my $levelid = $self -> _get_level_byname($level)
        or return undef;

    my $newh = $self -> {"dbh"} -> prepare("INSERT INTO `".$self -> {"settings"} -> {"database"} -> {"articlelevels"}."`
                                            (`article_id`, `level_id`)
                                            VALUES(?, ?)");
    my $rows = $newh -> execute($articleid, $levelid);
    return $self -> self_error("Unable to perform level relation insert: ". $self -> {"dbh"} -> errstr) if(!$rows);
    return $self -> self_error("Level relation insert failed, no rows inserted") if($rows eq "0E0");

    # FIXME: This ties to MySQL, but is more reliable that last_insert_id in general.
    #        Try to find a decent solution for this mess...
    # NOTE: the DBD::mysql documentation doesn't actually provide any useful information
    #       about what this will contain if the insert fails. In fact, DBD::mysql calls
    #       libmysql's mysql_insert_id(), which returns 0 on error (last insert failed).
    #       There, why couldn't they bloody /say/ that?!
    my $newid = $self -> {"dbh"} -> {"mysql_insertid"};

    return $self -> self_error("Unable to obtain id for new level relation row")
        if(!$newid);

    return $newid;
}


## @method private $ _get_feed_byname($name)
# Obtain the data for the feed with the specified name, if possible.
#
# @param name The name of the feed to get the ID for
# @return A reference to the feed data hash on success, undef on failure
sub _get_feed_byname {
    my $self  = shift;
    my $feed = shift;

    my $feedh = $self -> {"dbh"} -> prepare("SELECT * FROM `".$self -> {"settings"} -> {"database"} -> {"feeds"}."`
                                              WHERE `name` LIKE ?");
    $feedh -> execute($feed)
        or return $self -> self_error("Unable to execute feed lookup query: ".$self -> {"dbh"} -> errstr);

    my $levrow = $feedh -> fetchrow_hashref()
        or return $self -> self_error("Request for non-existent feed '$feed', giving up");

    return $levrow;
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
    try {
        given($mode) {
            when('year') {
                $start = DateTime -> new(year => $year, time_zone => "UTC");
                $end   = $start -> add(years => 1, seconds => -1);
            }
            when('month') {
                $start = DateTime -> new(year => $year, month => $month, time_zone => "UTC");
            $end   = $start -> add(months => 1, seconds => -1);
            }
            when('day') {
                $start = DateTime -> new(year => $year, month => $month, day => $day, time_zone => "UTC");
                $end   = $start -> add(months => 1, seconds => -1);
            }
            default {
                return (undef, undef);
            }
        }

    # If the start/end creation dies for some reason, log it, but there's not
    # much else can be done that that
    } catch {
        $self -> self_error("Error in DateTime operation: $_");
        return (undef, undef);
    }

    return ($start -> epoch(), $end -> epoch());
}

1;
