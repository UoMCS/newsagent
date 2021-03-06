# @file
# This file contains the implementation of the notification queue model.
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
#
package Newsagent::System::NotificationQueue;

use strict;
use experimental qw(smartmatch);
use base qw(Webperl::SystemModule); # This class extends the Newsagent block class
use Webperl::Utils qw(hash_or_hashref);
use v5.12;

# ============================================================================
#  Constructor

## @cmethod $ new(%args)
#
# @return A reference to a new Newsagent::System::NotificationQueue object on
#         success, undef on error.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = $class -> SUPER::new(@_)
        or return undef;

    $self -> _load_notification_method_modules()
        or return SystemModule::set_error($self -> errstr());

    return $self;
}


# ============================================================================
#  Interface

## @method $ get_methods()
# Return a reference to a hash containing the notification method modules.
#
# @return A reference to a hash of notification method modules
sub get_methods {
    my $self = shift;

    return $self -> {"notify_methods"};
}


## @method $ queue_notifications($articleid, $article, $userid, $is_draft, $used_methods, $send_mode, $send_after)
# Add the notifications for the specified article to the notification queue. This adds
# notifications for all the specified used methods, including setting up any method-
# specific data for the notifications.
#
# @param articleid    The ID of the article to add the notifications for.
# @param article      A reference to a hash containing the article data.
# @param userid       The ID of the user queueing the article.
# @param is_draft     True if the article is a draft, false otherwise.
# @param used_methods A reference to a hash of used methods. Each key should be the name
#                     of a notification method, and the value for each key should be a
#                     reference to an array of ids for rows in the recipient methods table.
# @param send_mode    The mode to use for sending (actually a UI convenience, as the send
#                     date is always stored as a date). Should be one of 'immediate', 'delay'
#                     or 'timed'. If 'immediate' or 'delay' then send_after is optional and
#                     will be calculated from the article publish time. If 'timed', send_after
#                     *must* be set. Defaults to 'delay'.
# @param send_after   The message will be held in the queue until at least this time, as
#                     a unix timestamp, has passed. If not specified, it is set to
#                     the article publish time (+ the standard safety delay if send_mode is
#                     'delay'.) This is a required field if send_mode is 'timed'.
# @return True on success, undef on error
sub queue_notifications {
    my $self         = shift;
    my $articleid    = shift;
    my $article      = shift;
    my $userid       = shift;
    my $is_draft     = shift;
    my $used_methods = shift;
    my $send_mode    = shift || 'delay';
    my $send_after   = shift;

    $self -> clear_error();

    # Check the send mode is valid.
    return $self -> self_error("Illigal release mode specified in call to queue_notifications")
        unless($send_mode eq "immediate" || $send_mode eq "delay" || $send_mode eq "timed");

    # Send time must be set if timed sending is specified
    return $self -> self_error("Unable to queue notifications: no time specified for delayed notification")
        if($send_mode eq "timed" && !defined($send_after));

    # Force calculation of send time for immediate and delayed notifications, prevents bogus timings
    # being provided for non-timed notifications.
    if($send_mode ne "timed") {
        $send_after = $article -> {"release_time"} || time();
        $send_after += (($self -> {"settings"} -> {"config"} -> {"Notification:hold_delay"} || 5) * 60)
            if($send_mode eq "delay");
    }

    foreach my $method (keys(%{$used_methods})) {
        my $newid = $self -> _queue_notification($articleid, $article, $userid, $self -> {"notify_methods"} -> {$method} -> get_id(), $is_draft, $send_mode, $send_after, $used_methods -> {$method})
            or return undef;

        my $dataid = $self -> {"notify_methods"} -> {$method} -> store_data($articleid, $article, $userid, $is_draft, $used_methods -> {$method});
        return $self -> self_error($self -> {"notify_methods"} -> {$method} -> errstr())
            if(!defined($dataid));

        $self -> set_notification_data($newid, $dataid) or return undef
            if($dataid);

        $self -> set_notification_status($newid, $is_draft ? "draft" : "pending")
            or return undef;
    }

    return 1;
}


## @method $ cancel_notifications($articleid, $methodid)
# Cancel all notifications for the specified method for the provided article.
#
# @param articleid The ID of the article to cancel notifications for
# @param methodid  An optional ID of the method to cancel the notification for. If
#                  this is not specified, ALL notifications for this article are
#                  cancelled.
# @return true on success, undef on error.
sub cancel_notifications {
    my $self      = shift;
    my $articleid = shift;
    my $methodid  = shift;
    my @params = ();
    my $where  = "";

    $self -> clear_error();

    $self -> _build_param(\@params, \$where, 'WHERE', 'article_id', $articleid  , '=');
    $self -> _build_param(\@params, \$where, 'AND'  , 'method_id' , $methodid, '=');

    my $updateh = $self -> {"dbh"} -> prepare("UPDATE `".$self -> {"settings"} -> {"database"} -> {"article_notify"}."`
                                               SET `status` = 'cancelled', `updated` = UNIX_TIMESTAMP()
                                               $where");
    my $rows = $updateh -> execute(@params);
    return $self -> self_error("Unable to update article notification: ".$self -> {"dbh"} -> errstr) if(!$rows);
    # Note that updating no rows here is potentially valid.

    return 1;
}


## @method $ send_pending_notification($notification, $allrecips)
# Send the specified notification to its recipients.
#
# @param notification A reference to a hash containing the notification to send
# @param allrecips    A reference to a hash containing the methods being used to
#                     send notifications for this article as keys, and arrays of
#                     recipient names for each method as values.
# @return A reference to an array containing send status information for each
#         recipient, or undef if a serious error occurred.
sub send_pending_notification {
    my $self         = shift;
    my $notification = shift;
    my $allrecips    = shift;

    $self -> clear_error();

    my $header = $self -> get_notification_status(id => $notification -> {"id"});
    if($header && $header -> {"status"} eq "pending") {
        # Mark as sending ASAP to prevent grabbing by another cron job on long jobs
        $self -> set_notification_status($notification -> {"id"}, "sending");

        # Fetch the article core data
        my $article = $self -> {"article"} -> get_article($notification -> {"article_id"})
            or return $self -> self_error($self -> {"article"} -> errstr());

        # Now fetch the list of recipient/method rows this notification is going to
        my $recipmeths = $self -> get_notification_targets($notification -> {"id"}, $notification -> {"year_id"})
            or return undef;

        # invoke the method sent
        my ($status, $results) = $self -> {"notify_methods"} -> {$notification -> {"name"}} -> send($article, $recipmeths, $allrecips, $self);

        # Work out the status message
        my $message = "";
        if($results) {
            my @states = ();
            foreach my $res (@{$results}) {
                my $msg = $res -> {"name"}.": ".$res -> {"state"};
                $msg .= (" (".$res -> {"message"}.")") if($res -> {"message"});
                push(@states, $msg);
            }

            $message = join("; ", @states);
        } else {
            $message = $self -> {"notify_methods"} -> {$notification -> {"name"}} -> errstr();
        }

        # always reset the status to something
        $self -> set_notification_status($notification -> {"id"}, $status || "failed", $message);

        # If the result is undef, propagate the error.
        return ($results || $self -> self_error($self -> {"notify_methods"} -> {$notification -> {"name"}} -> errstr()));
    } else {
        return [ { "name"    => "all",
                   "state"   => "skipped",
                   "message" => "Message status changed during cron processing."} ];
    }
}


## @method $ get_pending_notifications()
# Generate a list of currently pending notifications that are capable of being sent
#
# @return A reference to an array of pending article notifications
sub get_pending_notifications {
    my $self = shift;

    $self -> clear_error();

    my $pendingh = $self -> {"dbh"} -> prepare("SELECT `m`.`name`, `n`.`id`, `n`.`article_id`, `n`.`year_id`, `a`.`release_time`
                                                FROM `".$self -> {"settings"} -> {"database"} -> {"article_notify"}."` AS `n`,
                                                     `".$self -> {"settings"} -> {"database"} -> {"notify_methods"}."` AS `m`,
                                                     `".$self -> {"settings"} -> {"database"} -> {"articles"}."` AS `a`
                                                WHERE `m`.`id` = `n`.`method_id`
                                                AND `a`.`id` = `n`.`article_id`
                                                AND `n`.`status` = 'pending'
                                                AND `n`.`send_after` <= UNIX_TIMESTAMP()
                                                ORDER BY `a`.`release_time`, `m`.`name`");
    $pendingh -> execute()
        or return $self -> self_error("Unable to perform pending notification lookup: ".$self -> {"dbh"} -> errstr);

    return $pendingh -> fetchall_arrayref({});
}


## @method $ get_pending_notifications($after)
# Fetch the unix timestamp of the next notification send after the specified time.
#
# @param after The time to check for notifications to send from.
# @param The time the next notification should be sent on success, 0 if
#        there is no pending notification, undef on error.
sub get_next_notification_time {
    my $self  = shift;
    my $after = shift;

    my $pendingh = $self -> {"dbh"} -> prepare("SELECT `send_after`
                                                FROM `".$self -> {"settings"} -> {"database"} -> {"article_notify"}."`
                                                WHERE `status` = 'pending'
                                                AND `send_after` >= ?
                                                ORDER BY `send_after`
                                                LIMIT 1");
    $pendingh -> execute($after)
        or return $self -> self_error("Unable to perform pending notification lookup: ".$self -> {"dbh"} -> errstr);

    my $postat = $pendingh -> fetchrow_arrayref();

    return $postat ? $postat -> [0]: 0;
}


## @method @ get_notifications($articleid, $unsent)
# Obtain the notification data for the specfied article.
#
# @param articleid The article to fetch notification data for.
# @param unsent    If set to true, only notifications that have not been sent
#                  will be included in the result.
# @return Five values: the year id; a reference to a hash of used methods containing the
#         methods used for notifications (each value is an arrayref of recipient method ids);
#         a reference to a hash of enabled methods, a reference to an array of notification
#         time control hashes, and a reference to a hash of method-specific
#         data. Returns undef on error.
sub get_notifications {
    my $self      = shift;
    my $articleid = shift;
    my $unsent    = shift;

    return $self -> _get_article_notifications($articleid, $unsent);
}


## @method $ set_notification_data($nid, $dataid)
# Update the data id contained in the specified notification header.
#
# @param nid    The ID of the article notification header.
# @param dataid The ID of the data row to associate with this header.
# @return true on success, undef on error.
sub set_notification_data {
    my $self   = shift;
    my $nid    = shift;
    my $dataid = shift;

    $self -> clear_error();

    my $updateh = $self -> {"dbh"} -> prepare("UPDATE `".$self -> {"settings"} -> {"database"} -> {"article_notify"}."`
                                               SET `data_id` = ?
                                               WHERE id = ?");
    my $rows = $updateh -> execute($dataid, $nid);
    return $self -> self_error("Unable to update article notification: ".$self -> {"dbh"} -> errstr) if(!$rows);
    return $self -> self_error("Article notification update failed: no rows updated.") if($rows eq "0E0");

    return 1;
}


## @method $ set_notification_status($nid, $status, $message)
# Update the status for the specified article notification header.
#
# @param nid     The ID of the article notification header.
# @param status  The new status to set.
# @param message The message to set for the new status
# @return true on success, undef on error
sub set_notification_status {
    my $self    = shift;
    my $nid     = shift;
    my $status  = shift;
    my $message = shift;

    $self -> clear_error();

    my $updateh = $self -> {"dbh"} -> prepare("UPDATE `".$self -> {"settings"} -> {"database"} -> {"article_notify"}."`
                                               SET `status` = ?, `message` = ?, `updated` = UNIX_TIMESTAMP()
                                               WHERE id = ?");
    my $rows = $updateh -> execute($status, $message, $nid);
    return $self -> self_error("Unable to update article notification: ".$self -> {"dbh"} -> errstr) if(!$rows);
    return $self -> self_error("Article notification update failed: no rows updated.") if($rows eq "0E0");

    return 1;
}


## @method $ get_notification_status(%args)
# Obtain the status of the specified article notification header. Supported
# arguments are:
#
# - `id`: the id of the notification to get the data for. If this is set, the
#         following arguments are ignored.
# - `articleid`: the id of the article to fetch the data for. If set, `methodid` must be set.
# - `methodid`: the id of the method to filter on.
#
# @param args The arguments to use when querying the database.
# @return A reference to a hash containing the article notification header on success,
#         an empty hashref if no matching notification header exists, undef on error.
sub get_notification_status {
    my $self   = shift;
    my $args   = hash_or_hashref(@_);
    my @params;
    my $where  = "";

    $self -> clear_error();

    if($args -> {"id"}) {
        $self -> _build_param(\@params, \$where, "WHERE", 'id' , $args -> {'id'}, "=");
    } elsif($args -> {"articleid"} && $args -> {"methodid"}) {
        $self -> _build_param(\@params, \$where, "WHERE", 'articleid', $args -> {'articleid'}, "=");
        $self -> _build_param(\@params, \$where, "AND"  , 'methodid' , $args -> {'methodid'}, "=");
    } else {
        return $self -> self_error("Incorrect parameters provided to get_notification_status()");
    }

    my $stateh = $self -> {"dbh"} -> prepare("SELECT *
                                              FROM `".$self -> {"settings"} -> {"database"} -> {"article_notify"}."`
                                              $where
                                              LIMIT 1");
    $stateh -> execute(@params)
        or return $self -> self_error("Unable to execute notification lookup: ".$self -> {"dbh"} -> errstr());

    return ($stateh -> fetchrow_hashref() || {});
}


## @method $ get_notification_targets($nid, $yid)
# Obtain a list of the targets this notification should be sent to.
#
# @param nid The ID of the article notification header.
# @param yid The ID of the year to fetch any year-specific data for.
# @return A reference to an array of target hashes on success, undef on error
sub get_notification_targets {
    my $self = shift;
    my $nid  = shift;
    my $yid  = shift;

    $self -> clear_error();

    # First, get the list of recipients 'as-is'
    my $reciph = $self -> {"dbh"} -> prepare("SELECT `rm`.`id`, `r`.`name`, `r`.`shortname`, `rm`.`settings`
                                              FROM `".$self -> {"settings"} -> {"database"} -> {"article_notify_rms"}."` AS `a`,
                                                   `".$self -> {"settings"} -> {"database"} -> {"notify_matrix"}."` AS `rm`,
                                                   `".$self -> {"settings"} -> {"database"} -> {"notify_recipients"}."` AS `r`
                                              WHERE `r`.`id` = `rm`.`recipient_id`
                                              AND `rm`.`id` = `a`.`recip_meth_id`
                                              AND `a`.`article_notify_id` = ?");
    $reciph -> execute($nid)
        or return $self -> self_error("Unable to perform recipient method lookup: ".$self -> {"dbh"} -> errstr);

    my $targets = $reciph -> fetchall_arrayref({});

    # Query to fetch any year data if needed
    my $yearh = $self -> {"dbh"} -> prepare("SELECT `settings`
                                             FROM `".$self -> {"settings"} -> {"database"} -> {"notify_matrix_cfg"}."`
                                             WHERE `rm_id` = ?
                                             AND `year_id` = ?");
    foreach my $target (@{$targets}) {
        $yearh -> execute($target -> {"id"}, $yid)
            or return $self -> self_error("Unable to perform recipient method year data lookup: ".$self -> {"dbh"} -> errstr);

        # If there are year-specific settings, override the basic ones
        my $settings = $yearh -> fetchrow_arrayref();
        $target -> {"settings"} = $settings -> [0]
            if($settings && $settings -> [0]);

        # Do any year id substitutions needed
        $target -> {"settings"} =~ s/\{V_\[yearid\]\}/$yid/g;
   }

    return $targets;
}


## @method $ get_notification_dataid($articleid, $methodid)
# Given an article ID, fetch the data id for the current method from it.
#
# @param articleid The ID of the article to fetch the notification data for.
# @param methodid  The ID of the method to fetch the data for.
# @return The ID of the data row (or zero, if there is no data) on success, undef
#         on error.
sub get_notification_dataid {
    my $self      = shift;
    my $articleid = shift;
    my $methodid  = shift;

    $self -> clear_error();

    my $headh = $self -> {"dbh"} -> prepare("SELECT data_id
                                             FROM `".$self -> {"settings"} -> {"database"} -> {"article_notify"}."`
                                             WHERE `article_id` = ?
                                             AND `method_id` = ?");
    $headh -> execute($articleid, $methodid)
        or return $self -> self_error("Unable to execute notification header lookip: ".$self -> {"dbh"} -> errstr());

    my $dataid = $headh -> fetchrow_arrayref();
    return 0 if(!$dataid || !$dataid -> [0]);  # not having any data is not an error, just does nothing

    return $dataid -> [0];
}



## @method $ get_notification_articles($target, $method)
# Given a target and method, or an array of them, attempt to locate articles that
# have, or are going to have, notifications sent to that target via that method.
#
# @param target A notification target ID, or a reference to an array of IDs.
# @param method A notification method ID, or a reference to an array of IDs.
# @return A reference to an array of article hashes (exclusing summary and full text).
sub get_notification_articles {
    my $self   = shift;
    my $target = shift;
    my $method = shift;

    $self -> clear_error();

    my $recipmethods = $self -> _targetmethod_to_rm($target, $method)
        or return undef;

    # If there are no matching recipient/methods, give up
    return [] if(!scalar(@{$recipmethods}));

    # One or more recipmeths are available, build and run the query for them
    my @params;
    my $placeholders = "?";
    push(@params, @{$recipmethods});
    $placeholders .= (",?" x (scalar(@{$recipmethods}) - 1));

    my $articleh = $self -> {"dbh"} -> prepare("SELECT `a`.`id`, `a`.`creator_id`, `a`.`created`, `a`.`release_time`, `rm`.`recip_meth_id`, `n`.`status`, `u`.`username`, `u`.`realname`, `u`.`email`,`r`.`name`,`r`.`shortname`
                                                FROM `".$self -> {"settings"} -> {"database"} -> {"article_notify_rms"}."` AS `rm`,
                                                     `".$self -> {"settings"} -> {"database"} -> {"article_notify"}."` AS `n`,
                                                     `".$self -> {"settings"} -> {"database"} -> {"notify_matrix"}."` AS `m`,
                                                     `".$self -> {"settings"} -> {"database"} -> {"notify_recipients"}."` AS `r`,
                                                     `".$self -> {"settings"} -> {"database"} -> {"articles"}."` AS `a`,
                                                     `".$self -> {"settings"} -> {"database"} -> {"users"}."` AS `u`
                                                WHERE `a`.`id` = `n`.`article_id`
                                                AND (`n`.`status` = 'pending' OR `n`.`status` = 'sent' OR `n`.`status` = 'sending')
                                                AND `n`.`id` = `rm`.`article_notify_id`
                                                AND `m`.`id` = `rm`.`recip_meth_id`
                                                AND `r`.`id` = `m`.`recipient_id`
                                                AND `u`.`user_id` = `a`.`creator_id`
                                                AND `rm`.`recip_meth_id` IN ($placeholders)
                                                ORDER BY `a`.`release_time`");
    $articleh -> execute(@params)
        or return $self -> self_error("Unable to perform article lookup: ".$self -> {"dbh"} -> errstr);

    return $articleh -> fetchall_arrayref({});
}


# ============================================================================
#  Private functions

## @method private $ _load_notification_method_modules()
# Attempt to load all defined notification method modules and store them
# in the $self -> {"notify_methods"} hash reference.
#
# @return true on succes, undef on error
sub _load_notification_method_modules {
    my $self = shift;

    $self -> clear_error();

    my $modlisth = $self -> {"dbh"} -> prepare("SELECT meths.id, meths.name, mods.perl_module
                                                FROM `".$self -> {"settings"} -> {"database"} -> {"modules"}."` AS mods,
                                                     `".$self -> {"settings"} -> {"database"} -> {"notify_methods"}."` AS meths
                                                WHERE mods.module_id = meths.module_id
                                                AND mods.active = 1");
    $modlisth -> execute()
        or return $self -> self_error("Unable to execute notification module lookup: ".$self -> {"dbh"} -> errstr);

    while(my $modrow = $modlisth -> fetchrow_hashref()) {
        my $module = $self -> {"module"} -> load_module($modrow -> {"perl_module"}, "method_id" => $modrow -> {"id"},
                                                                                    "method_name" => $modrow -> {"name"})
            or return $self -> self_error("Unable to load notification module '".$modrow -> {"name"}."': ".$self -> {"module"} -> errstr());

        $self -> {"notify_methods"} -> {$modrow -> {"name"}} = $module;
    }

    return 1;
}


## @method private $ _queue_notification($articleid, $article, $userid, $methodid, $is_draft, $send_after, $recip_methods)
# Create a new notification header for the specified article and method. Note that
# this does not store any method-specific data, that should be done by the caller.
#
# @param articleid     The ID of the article to add the notifications for.
# @param article       A reference to a hash containing the article data.
# @param userid        The ID of the user queueing the article.
# @param methodid      The ID of the method this is a notification through.
# @param is_draft      True if the article is a draft, false otherwise.
# @param send_mode     The send mode (UI convenience value), one of 'immediate', 'delay', 'timed'.
# @param send_after    The unix timestamp for the point after which the message should be sent.
# @param recip_methods A reference to an array of ids for rows in the recipient methods table.
# @return The new notification header ID on success, undef on error
sub _queue_notification {
    my $self          = shift;
    my $articleid     = shift;
    my $article       = shift;
    my $userid        = shift;
    my $methodid      = shift;
    my $is_draft      = shift;
    my $send_mode     = shift;
    my $send_after    = shift;
    my $recip_methods = shift;

    $self -> clear_error();

    # First create the notification header for this article for the current
    # notification method.
    my $notifyh = $self -> {"dbh"} -> prepare("INSERT INTO `".$self -> {"settings"} -> {"database"} -> {"article_notify"}."`
                                               (article_id, method_id, year_id, updated, send_mode, send_after)
                                               VALUES(?, ?, ?, UNIX_TIMESTAMP(), ?, ?)");
    my $rows = $notifyh -> execute($articleid, $methodid, $article -> {"notify_matrix"} -> {"year"}, $send_mode, $send_after);
    return $self -> self_error("Unable to perform article notification insert: ". $self -> {"dbh"} -> errstr) if(!$rows);
    return $self -> self_error("Article notification insert failed, no rows inserted") if($rows eq "0E0");

    # FIXME: This ties to MySQL, but is more reliable that last_insert_id in general.
    #        Try to find a decent solution for this mess...
    # NOTE: the DBD::mysql documentation doesn't actually provide any useful information
    #       about what this will contain if the insert fails. In fact, DBD::mysql calls
    #       libmysql's mysql_insert_id(), which returns 0 on error (last insert failed).
    #       There, why couldn't they bloody /say/ that?!
    my $newid = $self -> {"dbh"} -> {"mysql_insertid"};

    return $self -> self_error("Unable to obtain id for new article notification row")
        if(!$newid);

    # Now there needs to be recipient/method map maps set up to tell this notification
    # method which recipients it needs to be sending to, and how
    my $rmmaph = $self -> {"dbh"} -> prepare("INSERT INTO `".$self -> {"settings"} -> {"database"} -> {"article_notify_rms"}."`
                                              (article_notify_id, recip_meth_id)
                                              VALUES(?, ?)");

    foreach my $rmid (@{$recip_methods}) {
        $rows = $rmmaph -> execute($newid, $rmid);
        return $self -> self_error("Unable to perform article notification rm map insert: ". $self -> {"dbh"} -> errstr) if(!$rows);
        return $self -> self_error("Article notification rm map insert failed, no rows inserted") if($rows eq "0E0");
    }

    return $newid;
}


## @method private $ _get_article_notifications($articleid, $unsent)
# Generate a hash containing the enabled recipients and methods, and a hash of used methods.
#
# @param articleid The article to fetch notification data for.
# @param unsent    If set to true, only notifications that have not been sent
#                  will be included in the result.
# @return Five values: the year id; a reference to a hash of used methods containing the
#         methods used for notifications (each value is an arrayref of recipient method ids);
#         a reference to a hash of enabled methods, a reference to an array of notification
#         time control hashes, and a reference to a hash of method-specific
#         data. Returns undef on error.
sub _get_article_notifications {
    my $self      = shift;
    my $articleid = shift;
    my $unsent    = shift || "";
    my ($year, $used, $enabled, $methods);

    $self -> clear_error();

    # fix up the sent check
    my $sent_check = $unsent ? "AND (n.status = 'pending' OR n.status = 'draft')" : "";

    # First we need to fetch the list of notification headers - this will give the
    # list of used methods, and can be used to look up the recipients
    my $notifyh = $self -> {"dbh"} -> prepare("SELECT n.*, m.name
                                               FROM `".$self -> {"settings"} -> {"database"} -> {"article_notify"}."` AS n,
                                                    `".$self -> {"settings"} -> {"database"} -> {"notify_methods"}."` AS m
                                               WHERE m.id = n.method_id
                                               AND n.article_id = ?
                                               $sent_check");

    # And a query will be needed to fetch recipients
    my $reciph = $self -> {"dbh"} -> prepare("SELECT rm.recipient_id
                                              FROM `".$self -> {"settings"} -> {"database"} -> {"article_notify_rms"}."` AS a,
                                                   `".$self -> {"settings"} -> {"database"} -> {"notify_matrix"}."` AS rm
                                              WHERE rm.id = a.recip_meth_id
                                              AND a.article_notify_id = ?");

    # Start the ball rolling on fetching headers
    $notifyh -> execute($articleid)
        or return $self -> self_error("Unable to fetch notification headers: ".$self -> {"dbh"} -> errstr());

    # Store send modes and times as a hash to begin with
    my $notify_at = {};
    while(my $header = $notifyh -> fetchrow_hashref()) {
        # All the years will be the same, so use the first one encountered
        $year = $header -> {"year_id"}
            if(!$year);

        # Fetch all recipient/method maps associated with this notification
        $reciph -> execute($header -> {"id"})
            or return $self -> self_error("Unable to fetch notification map: ".$self -> {"dbh"} -> errstr());

        while(my $recip = $reciph -> fetchrow_arrayref()) {
            push(@{$used -> {$header -> {"name"}}}, $recip -> [0]);
            $enabled -> {$recip -> [0]} -> {$header -> {"method_id"}} = 1;
        }

        # May as well fetch the method-specific data here, too!
        $methods -> {$header -> {"name"}} = $self -> {"notify_methods"} -> {$header -> {"name"}} -> get_data($articleid, $self);

        # Store the mode and time
        $notify_at -> {$header -> {"send_mode"}} -> {$header -> {"send_after"}} = 1;
    }

    # Now convert the send mode and time lists
    my @notify_list = ();
    foreach my $mode (keys %{$notify_at}) {
        given($mode) {
            # There should only be at most one immediate message
            when('immediate') { push(@notify_list, {"send_mode" => "immediate", "send_at" => (keys(%{$notify_at -> {$mode}}))[0]}); }

            # There should only be at most one delayed message
            when('delay') { push(@notify_list, {"send_mode" => "delay", "send_at" => (keys(%{$notify_at -> {$mode}}))[0]}); }

            # There may be any number of unique timed messages, though
            when('timed') {
                foreach my $time (keys(%{$notify_at -> {$mode}})) {
                    push(@notify_list, {"send_mode" => "timed", "send_at" => $time});
                }
            }
        }
    }

    # And sort the list into ascending chronological send order
    my @notify_sorted = sort { $a -> {"send_at"} <=> $b -> {"send_at"} } @notify_list;

    return ($year, $used, $enabled, \@notify_sorted, $methods);
}


sub _targetmethod_to_rm {
    my $self = shift;
    my $target = shift;
    my $method = shift;

    # Ensure the arguments are arrayrefs for ease of coding.
    $target = [ $target ] unless(ref($target) eq "ARRAY");
    $method = [ $method ] unless(ref($method) eq "ARRAY");

    my @params;
    my $where = "";

    $self -> _build_param(\@params, \$where, "WHERE", 'recipient_id', $target);
    $self -> _build_param(\@params, \$where, "AND"  , 'method_id'   , $method);

    my $methodh = $self -> {"dbh"} -> prepare("SELECT `id`
                                               FROM `".$self -> {"settings"} -> {"database"} -> {"notify_matrix"}."`
                                               $where");
    $methodh -> execute(@params)
        or return $self -> self_error("Unable to execute recipinet/method lookup: ".$self -> {"dbh"} -> errstr);

    my @recipmeths = ();
    while(my $meth = $methodh -> fetchrow_arrayref()) {
        push(@recipmeths, $meth -> [0]);
    }

    return \@recipmeths;
}


sub _build_param {
    my $self   = shift;
    my $params = shift;
    my $where  = shift;
    my $lead   = shift;
    my $field  = shift;
    my $value  = shift;
    my $op     = shift;

    if(defined($value)) {
        if(ref($value) eq "ARRAY") {
            push(@{$params}, @{$value});

            my $placeholders = "?";
            $placeholders .= (",?" x (scalar(@{$value}) - 1)) if(scalar(@{$value}) > 1);

            $$where .= " $lead `$field` IN (".$placeholders.")";
        } else {
            push(@{$params}, $value);
            $$where .= " $lead `$field` $op ?";
        }
    }
}




1;
