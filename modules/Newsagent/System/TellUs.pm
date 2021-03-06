## @file
# This file contains the implementation of the tellus message model.
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
use Webperl::Utils qw(hash_or_hashref);

# ============================================================================
#  Constructor

## @cmethod $ new(%args)
# Create a new Message object to manage tag allocation and lookup.
# The minimum values you need to provide are:
#
# * dbh       - The database handle to use for queries.
# * settings  - The system settings object
# * metadata  - The system Metadata object.
# * roles     - The system Roles object.
# * logger    - The system logger object.
#
# @param args A hash of key value pairs to initialise the object with.
# @return A new Message object, or undef if a problem occured.
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
#  Permission support

## @method $ moveto_allowed($queuid, $userid)
# Given a queue id, determine whether the user has permission to move messages
# into the queue.
#
# @param queueid The ID of the destination queue
# @param userid  The ID of the user.
# @return A reference to a hash containing the queue data on success, an
#         empty hashref if the user does not have permission, undef on error.
sub moveto_allowed {
    my $self    = shift;
    my $queueid = shift;
    my $userid  = shift;

    $self -> clear_error();

    # first check that the queue is valid
    my $queue = $self -> get_queue(id => $queueid)
        or return undef;

    # Now check access: users can move to queues they have moveto or manage access to
    return $queue
        if($self -> {"roles"} -> user_has_capability($queue -> {"metadata_id"}, $userid, "tellus.manage") ||
           $self -> {"roles"} -> user_has_capability($queue -> {"metadata_id"}, $userid, "tellus.moveto"));

    return {};
}


## @method $ update_allowed($msgid, $userid)
# Determine whether the user has manage access to the queue the selected message
# is in.
#
# @param msgid  The ID of the message the user is trying to move.
# @param userid the user attempting to move the message.
# @return true if the user can move the message, undef otherwise.
sub update_allowed {
    my $self   = shift;
    my $msgid  = shift;
    my $userid = shift;

    $self -> clear_error();

    my $metadata_id = $self -> get_message_metadata($msgid)
        or return undef;

    return $self -> {"roles"} -> user_has_capability($metadata_id, $userid, "tellus.manage");
}


# ============================================================================
#  Data access

## @method $ get_types()
# Fetch the list of types defined in the system.
#
# @return A reference to a list of tellus message types defined in the system.
sub get_types {
    my $self    = shift;
    my $entries = [];

    $self -> clear_error();

    my $typeh = $self -> {"dbh"} -> prepare("SELECT * FROM `".$self -> {"settings"} -> {"database"} -> {"tellus_types"}."`
                                             ORDER BY `position`");
    $typeh -> execute()
        or return $self -> self_error("Unable to execute type query: ".$self -> {"dbh"} -> errstr);

    while(my $type = $typeh -> fetchrow_hashref()) {
        push(@{$entries}, {"value" => $type -> {"id"},
                           "name"  => $type -> {"name"}});
    }

    return $entries;
}


## @method $ get_queue($args)
# Obtain the data for teh quested queue. Note that this does not determine whether
# the user actually has permission to do anything with the queue, it just fetches
# its information from the database.
#
# Value arguments are:
# - id: search for the queue by id
# - name: search for the queue by name
# Only one may be specified at a time.
#
# @param args A hash, or reference to a hash, of arguments.
# @return A reference to a hash containing the queue data on success, undef on error.
sub get_queue {
    my $self = shift;
    my $args = hash_or_hashref(@_);

    $self -> clear_error();

    my ($where, $param);
    if($args -> {"id"}) {
        $where = "`id` = ?";
        $param = $args -> {"id"};
    } elsif($args -> {"name"}) {
        $where = "`name` LIKE ?";
        $param = $args -> {"name"};
    } else {
        return $self -> self_error("no valid argument specified in call to get_queue()");
    }

    my $queueh = $self -> {"dbh"} -> prepare("SELECT * FROM `".$self -> {"settings"} -> {"database"} -> {"tellus_queues"}."`
                                              WHERE $where
                                              LIMIT 1");
    $queueh -> execute($param)
        or return $self -> self_error("Unable to execute queue query: ".$self -> {"dbh"} -> errstr);

    return ($queueh -> fetchrow_hashref() || $self -> self_error("Request for non-existent queue $param"));
}


## @method $ get_queues($userid, $access)
# Fetch the list of queues defined in the system the user can perform the requested
# action in.
#
# Supported access options are:
# - 'additem' add items to this queue (implies it is visible to the user, but existing
#             items in the list may not be
# - 'moveto' user can move items into this queue (without necessarily being able to view)
# - 'manage' has full access to the queue, can view and reject/delete items.
#
# @param userid The ID of the user to fetch the authorised queue list for
# @param access The operation the user wants to perform. If this is a reference to an
#               array, if the user has any of the listed access the queue is included.
# @return A reference to a list of queues the user has access to.
sub get_queues {
    my $self    = shift;
    my $userid  = shift;
    my $access  = shift;
    my $entries = [];

    $access = [ $access ] if(ref($access) ne "ARRAY");

    $self -> clear_error();

    my $queueh = $self -> {"dbh"} -> prepare("SELECT * FROM `".$self -> {"settings"} -> {"database"} -> {"tellus_queues"}."`
                                              ORDER BY `position`, `name`");
    $queueh -> execute()
        or return $self -> self_error("Unable to execute queue query: ".$self -> {"dbh"} -> errstr);

    while(my $queue = $queueh -> fetchrow_hashref()) {
        foreach my $capability (@{$access}) {
            # Only add the queue to the result list if the user has the required capability
            if($self -> {"roles"} -> user_has_capability($queue -> {"metadata_id"}, $userid, "tellus.$capability")) {
                $queue -> {"value"} = $queue -> {"id"};

                push(@{$entries}, $queue);
                last;
            }
        }
    }

    return $entries;
}


## @method $ active_queue($queue, $userid)
# Obtain the data for the active queue. If no queue name is provided, or the user
# does not have manage access to the queue, this will choose the first queue the user
# has manage access to (in alphabetical order) and return the data for that.
#
# @param queue  The name of the active queue.
# @param userid The ID of the user fetching the queue data.
# @return A reference to a hash containing the queue data to use as the active queue.
sub active_queue {
    my $self   = shift;
    my $queue  = shift;
    my $userid = shift;

    $self -> clear_error();

    # Try to locate a queue with the specified name
    my $queueh = $self -> {"dbh"} -> prepare("SELECT * FROM `".$self -> {"settings"} -> {"database"} -> {"tellus_queues"}."`
                                              WHERE `name` LIKE ?
                                              LIMIT 1");
    $queueh -> execute($queue)
        or return $self -> self_error("Unable to execute queue query: ".$self -> {"dbh"} -> errstr);

    # If the queue data has been found, and the user has access to it, return the data
    my $queuedata = $queueh -> fetchrow_hashref();
    return $queuedata if($queuedata && $self -> {"roles"} -> user_has_capability($queuedata -> {"metadata_id"}, $userid, "tellus.manage"));

    # queue is bad/user doesn't have access, so fetch the queues the user does have access to
    my $queues = $self -> get_queues($userid, "manage")
        or return undef;

    return $self -> self_error("User does not have manage access to any queues")
        if(!scalar(@{$queues}));

    return $queues -> [0];
}


## @method $ get_queue_stats($queueid)
# Fetch information about the number of messages in the specified queue. This
# determines how many messages are in the queue, including the number of unread
# messages and the number of rejected.
#
# @param queueid The ID of the queue to fetch the information for.
# @return A reference to a hash containing the queue statistics on success, undef
#         if an error occurs.
sub get_queue_stats {
    my $self    = shift;
    my $queueid = shift;

    $self -> clear_error();

    my $counth = $self -> {"dbh"} -> prepare("SELECT COUNT(*)
                                              FROM `".$self -> {"settings"} -> {"database"} -> {"tellus_messages"}."`
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


## @method $ get_queue_messages($settings)
# Fetch messages in the specified queue, ordered by descending creation
# date. If alternative orderings are needed, the caller should re-sort the list.
#
# Supported arguments in the setting are:
# - queueid The ID of the queue to fetch messages from (required!)
# - count   The number of messages to return
# - offset  An offset to start returning messages from. The first message is
#           at offset = 0
# - show_rejected If set, messages with "rejected" status are included
# - types   A reference to an array of type IDs to include. If not specified,
#           all types are included.
#
# @param settings A reference to a hash containing the settings to use when
#                 fetching the messages
# @return A reference to an array of hashrefs containing the message information
#         but not including the message text on success, undef on error.
sub get_queue_messages {
    my $self     = shift;
    my $settings = shift;

    $self -> clear_error();

    my $modes = "'new', 'read', 'promoted'";
    $modes .= ",'rejected'" if($settings -> {"show_rejected"});

    my $types = "";
    $types = "AND `a`.`type_id` IN (".join(",", $settings -> {"types"}).")"
        if($settings -> {"types"} && scalar($settings -> {"types"}));

    # limiting
    my $limit = "";
    $limit = " LIMIT ".$settings -> {"offset"}.",".$settings -> {"count"}
        if(defined($settings -> {"offset"}) && $settings -> {"count"});

    my $geth = $self -> {"dbh"} -> prepare("SELECT `a`.*, `u`.`user_id`, `u`.`username`, `u`.`realname`, `u`.`email`, `t`.`name`
                                            FROM `".$self -> {"settings"} -> {"database"} -> {"tellus_messages"}."` AS `a`
                                            LEFT JOIN `".$self -> {"settings"} -> {"database"} -> {"users"}."` AS `u`
                                                ON `u`.`user_id` = `a`.`creator_id`
                                            LEFT JOIN `".$self -> {"settings"} -> {"database"} -> {"tellus_types"}."` AS `t`
                                                ON `t`.`id` = `a`.`type_id`
                                            WHERE `a`.`queue_id` = ?
                                            AND `a`.`state` IN ($modes)
                                            $types
                                            ORDER BY `a`.`created` DESC
                                            $limit");
    $geth -> execute($settings -> {"queueid"})
        or return $self -> self_error("Unable to execute queue query: ".$self -> {"dbh"} -> errstr);

    my $messages = $geth -> fetchall_arrayref({});

    # Now find out how many entries there are without limiting, this can be done rather faster and smaller
    my $counth = $self -> {"dbh"} -> prepare("SELECT COUNT(*)
                                              FROM `".$self -> {"settings"} -> {"database"} -> {"tellus_messages"}."` AS `a`
                                              WHERE `a`.`queue_id` = ?
                                              AND `a`.`state` IN ($modes)
                                              $types");
    $counth -> execute($settings -> {"queueid"})
        or return $self -> self_error("Unable to execute queue count query: ".$self -> {"dbh"} -> errstr);

    my $count = $counth -> fetchrow_arrayref() || [ 0 ];

    return {"messages" => $messages,
            "metadata" => { "count" => $count -> [0]}
           };
}


## @method $ get_queue_notify_recipients($queuid)
# Fetch the list of userids for users who should be notfied about changes
# in the specified queue.
#
# @param queueid The ID of the queue to fetch the notification addresses for
# @return A reference to an array of user ids on success, undef on error.
#         Note that, if no notification recipients have been set for the queue, this
#         will return an empty array.
sub get_queue_notify_recipients {
    my $self    = shift;
    my $queueid = shift;
    my $result  = [];

    $self -> clear_error();

    my $notifyh = $self -> {"dbh"} -> prepare("SELECT `user_id`
                                               FROM `".$self -> {"settings"} -> {"database"} -> {"tellus_notify"}."`
                                               WHERE `queue_id` = ?");
    $notifyh -> execute($queueid)
        or return $self -> self_error("Unable to execute queue notification query: ".$self -> {"dbh"} -> errstr);

    while(my $user = $notifyh -> fetchrow_arrayref()) {
        push(@{$result}, $user -> [0]);
    }

    return $result;
}


## @method $ get_message($messageid)
# Obtain the data for the specified message.
#
# @param messageid The ID of the message to fetch the data for.
# @return A reference to a hash containing the message data on success, undef
#         on error
sub get_message {
    my $self      = shift;
    my $messageid = shift;

    $self -> clear_error();

    my $geth = $self -> {"dbh"} -> prepare("SELECT `a`.*, `u`.`user_id`, `u`.`username`, `u`.`realname`, `u`.`email`, `t`.`name` AS `typename`, `q`.`name` AS `queuename`, `q`.`metadata_id`
                                            FROM `".$self -> {"settings"} -> {"database"} -> {"tellus_messages"}."` AS `a`
                                            LEFT JOIN `".$self -> {"settings"} -> {"database"} -> {"users"}."` AS `u`
                                                ON `u`.`user_id` = `a`.`creator_id`
                                            LEFT JOIN `".$self -> {"settings"} -> {"database"} -> {"tellus_types"}."` AS `t`
                                                ON `t`.`id` = `a`.`type_id`
                                            LEFT JOIN `".$self -> {"settings"} -> {"database"} -> {"tellus_queues"}."` AS `q`
                                                ON `q`.`id` = `a`.`queue_id`
                                            WHERE `a`.`id` = ?");
    $geth -> execute($messageid)
        or return $self -> self_error("Unable to execute message query: ".$self -> {"dbh"} -> errstr);

    return ($geth -> fetchrow_hashref() || $self -> self_error("Request for non-existent message with ID $messageid"));
}


## @method $ get_message_metadata($messageid)
# Obtain the metadata ID for the queue containing the specified message.
#
# @param messageid The ID of the message to fetch the metadata ID for.
# @return A reference to a hash containing the message data on success, undef
#         on error
sub get_message_metadata {
    my $self      = shift;
    my $messageid = shift;

    $self -> clear_error();

    # Get the metadata id for the queue based on the message
    my $mdh = $self -> {"dbh"} -> prepare("SELECT `q`.`metadata_id`
                                           FROM `".$self -> {"settings"} -> {"database"} -> {"tellus_messages"}."` AS `m`,
                                                `".$self -> {"settings"} -> {"database"} -> {"tellus_queues"}."` AS `q`
                                           WHERE `q`.`id` = `m`.`queue_id`
                                           AND `m`.`id` = ?");
    $mdh -> execute($messageid)
        or return $self -> self_error("Unable to execute metadata query: ".$self -> {"dbh"} -> errstr);

    my $metadata = $mdh -> fetchrow_arrayref()
        or return $self -> self_error("Unable to fetch metadata id for message $messageid");

    return $metadata -> [0];
}


# ============================================================================
#  Storage and addition

## @method $ add_message($message, $userid)
# Add an entry to the tellus message table. This adds the specified message to the tellus
# message list, and sets up the supporting information for it.
#
# @param message A reference to a hash containing the message data.
# @param userid  The ID of the user adding the message.
# @return The ID of the new message on success, undef on error.
sub add_message {
    my $self    = shift;
    my $message = shift;
    my $userid  = shift;

    $self -> clear_error();

    my $addh = $self -> {"dbh"} -> prepare("INSERT INTO `".$self -> {"settings"} -> {"database"} -> {"tellus_messages"}."`
                                            (creator_id, created, queue_id, queued, type_id, updated, updated_by, state, reason, message)
                                            VALUES(?, UNIX_TIMESTAMP(), ?, UNIX_TIMESTAMP(), ?, UNIX_TIMESTAMP(), ?, 'new', 'created', ?)");
    my $rows = $addh -> execute($userid, $message -> {"queue"}, $message -> {"type"}, $userid, $message -> {"message"});
    return $self -> self_error("Unable to perform message insert: ". $self -> {"dbh"} -> errstr) if(!$rows);
    return $self -> self_error("Message insert failed, no rows inserted") if($rows eq "0E0");

    # MYSQL: This ties to MySQL, but is more reliable that last_insert_id in general.
    #        Try to find a decent solution for this mess...
    # NOTE: the DBD::mysql documentation doesn't actually provide any useful information
    #       about what this will contain if the insert fails. In fact, DBD::mysql calls
    #       libmysql's mysql_insert_id(), which returns 0 on error (last insert failed).
    #       There, why couldn't they bloody /say/ that?!
    my $newid = $self -> {"dbh"} -> {"mysql_insertid"};

    return $self -> self_error("Unable to obtain id for new message row")
        if(!$newid);

    # At this point the message is in the system and waiting in a queue.
    return $newid;
}


## @method $ set_message_status($messageid, $userid, $state, $reason)
# Set the state for the specified message. This updates the message's state to the specified
# value, and changes its 'updated' timestamp.
#
# @param messageid The ID of the tellus message to update
# @param state     The new state to set or the message
# @return A reference to a hash containing the message data on success, undef on error
sub set_message_status {
    my $self      = shift;
    my $messageid = shift;
    my $userid    = shift;
    my $state     = shift;
    my $reason    = shift || "";

    $self -> clear_error();

    my $seth = $self -> {"dbh"} -> prepare("UPDATE `".$self -> {"settings"} -> {"database"} -> {"tellus_messages"}."`
                                            SET `state` = ?, `updated` = UNIX_TIMESTAMP(), `updated_by` = ?, `reason` = ?
                                            WHERE `id` = ?");
    my $result = $seth -> execute($state, $userid, $reason, $messageid);
    return $self -> self_error("Unable to update message state: ".$self -> {"dbh"} -> errstr) if(!$result);
    return $self -> self_error("Message state update failed: no rows updated.") if($result eq "0E0");

    return $self -> get_message($messageid);
}


## @method $ set_message_queue($messageid, $userid, $queueid)
# Set the queue for the specified message. This updates the message's queue to the specified
# value, and changes its 'queued' and 'updated' timestamps. Note that the caller should
# probably notify the target queue owners of this change, as this function will not do that.
#
# @param messageid The ID of the tellus message to update
# @param userid    The ID of the user moving the message.
# @param queueid   The ID of the new queue to set or the message
# @return A reference to a hash containing the message data on success, undef on error
sub set_message_queue {
    my $self      = shift;
    my $messageid = shift;
    my $userid    = shift;
    my $queueid   = shift;

    $self -> clear_error();

    my $seth = $self -> {"dbh"} -> prepare("UPDATE `".$self -> {"settings"} -> {"database"} -> {"tellus_messages"}."`
                                            SET `queue_id` = ?, `queued` = UNIX_TIMESTAMP(), `updated` = UNIX_TIMESTAMP(), `updated_by` = ?
                                            WHERE `id` = ?");
    my $result = $seth -> execute($queueid, $userid, $messageid);
    return $self -> self_error("Unable to update message queue: ".$self -> {"dbh"} -> errstr) if(!$result);
    return $self -> self_error("Message queue update failed: no rows updated.") if($result eq "0E0");

    return $self -> get_message($messageid);
}


1;
