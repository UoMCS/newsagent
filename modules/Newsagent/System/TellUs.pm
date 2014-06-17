## @file
# This file contains the implementation of the tellus article model.
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
package Newsagent::System::TellUs;

use strict;
use base qw(Webperl::SystemModule); # This class extends the Newsagent block class
use v5.12;

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

    return $self;
}


# ============================================================================
#  Data access

## @method $ get_queue_stats($queueid)
# Fetch information about the number of articles in the specified queue. This
# determines how many articles are in the queue, including the number of unread
# articles and the number of rejected.
#
# @param queueid The ID of the queue to fetch the information for.
# @return A reference to a hash containing the queue statistics on success, undef
#         if an error occurs.
sub get_queue_stats {
    my $self    = shift;
    my $queueid = shift;

    $self -> clear_error();

    my $counth = $self -> {"dbh"} -> prepare("SELECT COUNT(*)
                                              FROM `".$self -> {"settings"} -> {"database"} -> {"tellus_articles"}."`
                                              WHERE `queue_id` = ?
                                              AND `state` = ?");
    my @states = ("new", "viewed", "rejected");
    my $counts = { "total" => 0 };
    foreach my $state (@states) {
        $counth -> execute($queueid, $state)
            or return $self -> self_error("Unable to execute queue query: ".$self -> {"dbh"} -> errstr);

        my $count = $counth -> fetchrow_arrayref();
        $counts -> {"total"} += $count -> [0];
        $counts -> {$state} = $count -> [0];
    }

    return $counts;
}


## @method $ get_queue_articles($queueid, $show_rejected)
# Fetch all the articles in the specified queue, ordered by descending creation
# date. If alternative orderings are needed, the caller should re-sort the list.
#
# @param queueid The ID of the queue to fetch the articles for. Note that this
#                *does not* check access to the queue for the current user.
# @param show_rejected If true, include rejected items in the list.
# @return A reference to an array of hashrefs containing the article information
#         but not including the article text on success, undef on error.
sub get_queue_articles {
    my $self          = shift;
    my $queueid       = shift;
    my $show_rejected = shift;

    $self -> clear_error();

    my $modes = "'new', 'viewed'";
    $modes .= ",'rejected'" if($show_rejected);

    my $geth = $self -> {"dbh"} -> prepare("SELECT `a`.`creator_id`, `a`.`created`, `a`.`queue_id`, `a`.`queued`, `a`.`updated`, `a`.`type_id`, `a`.`state`, `u`.`user_id`, `u`.`username`, `u`.`realname`, `u`.`email`, `t`.`name`
                                            FROM `".$self -> {"settings"} -> {"database"} -> {"tellus_articles"}."` AS `a`
                                            LEFT JOIN `".$self -> {"settings"} -> {"database"} -> {"users"}."` AS `u`
                                                ON `u`.`user_id` = `a`.`creator_id`
                                            LEFT JOIN `".$self -> {"settings"} -> {"database"} -> {"tellus_types"}."` AS `t`
                                                ON `t`.`id` = `a`.`type_id`
                                            WHERE `q`.`queue_id` = ?
                                            AND `a`.`state` IN ($modes)
                                            ORDER BY `a`.`created`");
    $geth -> execute($queueid)
        or return $self -> self_error("Unable to execute queue query: ".$self -> {"dbh"} -> errstr);

    return $geth -> fetchall_arrayref({});
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

    $self -> clear_error();

    my $geth = $self -> {"dbh"} -> prepare("SELECT `a`.*, `u`.`user_id`, `u`.`username`, `u`.`realname`, `u`.`email`, `t`.`name`
                                            FROM `".$self -> {"settings"} -> {"database"} -> {"tellus_articles"}."` AS `a`
                                            LEFT JOIN `".$self -> {"settings"} -> {"database"} -> {"users"}."` AS `u`
                                                ON `u`.`user_id` = `a`.`creator_id`
                                            LEFT JOIN `".$self -> {"settings"} -> {"database"} -> {"tellus_types"}."` AS `t`
                                                ON `t`.`id` = `a`.`type_id`
                                            WHERE `a`.`id` = ?");
    $geth -> execute($articleid)
        or return $self -> self_error("Unable to execute article query: ".$self -> {"dbh"} -> errstr);

    my $article = $articleh -> fetchrow_hashref()
        or return $self -> self_error("Request for non-existent article with ID $articleid");

    return $article;
}


# ============================================================================
#  Storage and addition

## @method $ add_article($article)
# Add an entry to the tellus article table. This adds the specified article to the tellus
# article list, and sets up the supporting information for it.
#
# @param article A reference to a hash containing the article data.
# @return The ID of the new article on success, undef on error.
sub add_article {
    my $self    = shift;
    my $article = shift;

    $self -> clear_error();

    my $addh = $self -> {"dbh"} -> prepare("INSERT INTO `".$self -> {"settings"} -> {"database"} -> {"tellus_articles"}."`
                                            (creator_id, created, queue_id, queued, type_id, updated, state, article)
                                            VALUES(?, UNIX_TIMESTAMP(), ?, UNIX_TIMESTAMP(), ?, UNIX_TIMESTAMP(), 'new', ?)");
    my $rows = $addh -> execute($article -> {"user_id"}, $article -> {"queue_id"}, $article -> {"type_id"}, $article -> {"article"});
    return $self -> self_error("Unable to perform article insert: ". $self -> {"dbh"} -> errstr) if(!$rows);
    return $self -> self_error("Article insert failed, no rows inserted") if($rows eq "0E0");

    # MYSQL: This ties to MySQL, but is more reliable that last_insert_id in general.
    #        Try to find a decent solution for this mess...
    # NOTE: the DBD::mysql documentation doesn't actually provide any useful information
    #       about what this will contain if the insert fails. In fact, DBD::mysql calls
    #       libmysql's mysql_insert_id(), which returns 0 on error (last insert failed).
    #       There, why couldn't they bloody /say/ that?!
    my $newid = $self -> {"dbh"} -> {"mysql_insertid"};

    return $self -> self_error("Unable to obtain id for new article row")
        if(!$newid);

    # At this point the article is in the system and waiting in a queue.
    return $newid;
}


## @method $ set_article_status($articleid, $state)
# Set the state for the specified article. This updates the article's state to the specified
# value, and changes its 'updated' timestamp.
#
# @param articleid The ID of the tellus article to update
# @param state     The new state to set or the article
# @return A reference to a hash containing the article data on success, undef on error
sub set_article_status {
    my $self      = shift;
    my $articleid = shift;
    my $state     = shift;

    $self -> clear_error();

    my $seth = $self -> {"dbh"} -> prepare("UPDATE `".$self -> {"settings"} -> {"database"} -> {"tellus_articles"}."`
                                            SET `state` = ?, `updated` = UNIX_TIMESTAMP()
                                            WHERE `id` = ?");
    my $rows = $seth -> execute($state, $articleid);
    return $self -> self_error("Unable to update article state: ".$self -> {"dbh"} -> errstr) if(!$result);
    return $self -> self_error("Article state update failed: no rows updated.") if($result eq "0E0");

    return $self -> get_article($articleid);
}


## @method $ set_article_queue($articleid, $queueid)
# Set the queue for the specified article. This updates the article's queue to the specified
# value, and changes its 'queued' and 'updated' timestamps. Note that the caller should
# probably notify the target queue owners of this change, as this function will not do that.
#
# @param articleid The ID of the tellus article to update
# @param queueid   The ID of the new queue to set or the article
# @return A reference to a hash containing the article data on success, undef on error
sub set_article_queue {
    my $self      = shift;
    my $articleid = shift;
    my $queueid   = shift;

    $self -> clear_error();

    my $seth = $self -> {"dbh"} -> prepare("UPDATE `".$self -> {"settings"} -> {"database"} -> {"tellus_articles"}."`
                                            SET `queue_id` = ?, `queued` = UNIX_TIMESTAMP(), `updated` = UNIX_TIMESTAMP()
                                            WHERE `id` = ?");
    my $rows = $seth -> execute($queueid, $articleid);
    return $self -> self_error("Unable to update article queue: ".$self -> {"dbh"} -> errstr) if(!$result);
    return $self -> self_error("Article queue update failed: no rows updated.") if($result eq "0E0");

    return $self -> get_article($articleid);
}


1;
