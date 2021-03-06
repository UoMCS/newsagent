## @file
# This file contains the implementation of the schedule model.
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
package Newsagent::System::Schedule;

use strict;
use base qw(Webperl::SystemModule); # This class extends the Newsagent block class
use DateTime::Event::Cron;
use List::Util qw(min);
use JSON;
use XML::Simple;
use Webperl::Utils qw(path_join);
use v5.12;
use Data::Dumper;

## @cmethod $ new(%args)
# Create a new Schedule object to manage tag allocation and lookup.
# The minimum values you need to provide are:
#
# * dbh       - The database handle to use for queries.
# * settings  - The system settings object
# * metadata  - The system Metadata object.
# * roles     - The system Roles object.
# * logger    - The system logger object.
#
# @param args A hash of key value pairs to initialise the object with.
# @return A new Schedule object, or undef if a problem occured.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = $class -> SUPER::new(@_)
        or return undef;

    # Check that the required objects are present
    return Webperl::SystemModule::set_error("No metadata object available.") if(!$self -> {"metadata"});
    return Webperl::SystemModule::set_error("No roles object available.")    if(!$self -> {"roles"});

    # The roles that determine whether someohe has access to a given newsletter.
    $self -> {"defined_roles"} = ['newsletter.contribute', 'newsletter.manager', 'newsletter.publisher'];

    return $self;
}


# ============================================================================
#  Data access

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

    my $sectionh = $self -> {"dbh"} -> prepare("SELECT sec.id, sec.metadata_id, sec.name, sec.schedule_id, sch.name AS schedule_name, sch.description AS schedule_desc, sch.schedule
                                                FROM ".$self -> {"settings"} -> {"database"} -> {"schedule_sections"}." AS sec,
                                                     ".$self -> {"settings"} -> {"database"} -> {"schedules"}." AS sch
                                                WHERE sch.id = sec.schedule_id
                                                ORDER BY sch.description, sec.sort_order");
    $sectionh -> execute()
        or return $self -> self_error("Unable to execute section lookup query: ".$self -> {"dbh"} -> errstr);

    my $result = {};
    while(my $section = $sectionh -> fetchrow_hashref()) {
        if($self -> {"roles"} -> user_has_capability($section -> {"metadata_id"}, $userid, "newsletter.schedule") ||
           $self -> {"roles"} -> user_has_capability($section -> {"metadata_id"}, $userid, "newsletter.layout")) {
            # Store the section name and id.
            push(@{$result -> {"id_".$section -> {"schedule_id"}} -> {"sections"}},
                 {"value" => $section -> {"id"},
                  "name"  => $section -> {"name"}});

            # And set the schedule fields if needed.
            if(!$result -> {"id_".$section -> {"schedule_id"}} -> {"schedule_name"}) {
                $result -> {"id_".$section -> {"schedule_id"}} -> {"schedule_name"} = $section -> {"schedule_name"};
                $result -> {"id_".$section -> {"schedule_id"}} -> {"schedule_desc"} = $section -> {"schedule_desc"};

                # Work out when the next two runs of the schedule are
                if($section -> {"schedule"}) {
                    $result -> {"id_".$section -> {"schedule_id"}} -> {"next_run"} = $self -> get_newsletter_issuedates($section);
                    $result -> {"id_".$section -> {"schedule_id"}} -> {"schedule_mode"} = "auto";
                } else {
                    $result -> {"id_".$section -> {"schedule_id"}} -> {"next_run"} = [ "", "" ];
                    $result -> {"id_".$section -> {"schedule_id"}} -> {"schedule_mode"} = "manual";
                }

                # And store the cron for later user in the view
                $result -> {"id_".$section -> {"schedule_id"}} -> {"schedule"} = $section -> {"schedule"};
            }
        }
    }

    foreach my $id (sort {$result -> {$a} -> {"schedule_desc"} cmp $result -> {$b} -> {"schedule_desc"}} keys(%{$result})) {
        push(@{$result -> {"_schedules"}}, {"value" => $result -> {$id} -> {"schedule_name"},
                                            "name"  => $result -> {$id} -> {"schedule_desc"},
                                            "mode"  => $result -> {$id} -> {"schedule_mode"}});
    }

    return $result;
}


## @method $ get_schedule_byid($id)
# Given a schedule ID, fetch the data for the schedule with that id.
#
# @param id The ID of the schedule to fetch the data for.
# @return A reference to a hash containing the schedule data on success,
#         undef on error or if the schedule does not exist.
sub get_schedule_byid {
    my $self = shift;
    my $id   = shift;

    $self -> clear_error();

    my $schedh = $self -> {"dbh"} -> prepare("SELECT * FROM `".$self -> {"settings"} -> {"database"} -> {"schedules"}."`
                                              WHERE `id` = ?");
    $schedh -> execute($id)
        or return $self -> self_error("Unable to execute schedule lookup query: ".$self -> {"dbh"} -> errstr);

    return ($schedh -> fetchrow_hashref() || $self -> self_error("Request for non-existant schedule $id"));
}


## @method $ get_schedule_byname($name)
# Given a schedule name, fetch the data for the schedule with that name. If
# you are unwise enough to have multiple schedules with the same name, this
# will return the first.
#
# @param name The name of the schedule to fetch the data for.
# @return A reference to a hash containing the schedule data on success,
#         undef on error or if the schedule does not exist.
sub get_schedule_byname {
    my $self = shift;
    my $name = shift;

    $self -> clear_error();

    my $shedh = $self -> {"dbh"} -> prepare("SELECT * FROM `".$self -> {"settings"} -> {"database"} -> {"schedules"}."`
                                             WHERE `name` LIKE ?
                                             LIMIT 1");
    $shedh -> execute($name)
        or return $self -> self_error("Unable to execute schedule lookup query: ".$self -> {"dbh"} -> errstr);

    return ($shedh -> fetchrow_hashref() || $self -> self_error("Request for non-existant schedule $name"));
}


## @method $ get_section($id)
# Given a section ID, return the data for the section, and the schedule it
# is part of.
#
# @param id The ID of the section to fetch the data for.
# @return A reference to the section data (with the schedule in a key
#         called "schedule") on success, undef on error/bad section
sub get_section {
    my $self = shift;
    my $id   = shift;

    $self -> clear_error();

    my $secth = $self -> {"dbh"} -> prepare("SELECT * FROM `".$self -> {"settings"} -> {"database"} -> {"schedule_sections"}."`
                                             WHERE `id` = ?");
    $secth -> execute($id)
        or return $self -> self_error("Unable to execute section lookup query: ".$self -> {"dbh"} -> errstr);

    my $section = $secth -> fetchrow_hashref()
        or return $self -> self_error("Request for non-existant section '$id'");

    # Pull the schedule data in as most things using sections will need it.
    $section -> {"schedule"} = $self -> get_schedule_byid($section -> {"schedule_id"})
        or return undef;

    return $section;
}


## @method $ get_newsletter($name, $userid, $full, $issue)
# Locate a newsletter by name.
#
# @param name   The name of the newsletter to fetch.
# @param userid An optional userid. If specified, the user must have
#               schedule access to the newsletter or a section of it.
# @param full   If true, fetch the full data for the newsletter.
# @param issue  An optional reference to an array containing the year,
#               month, and day of the issue to generate.
# @return A reference to a hash containing the newsletter on success, undef on error.
sub get_newsletter {
    my $self   = shift;
    my $name   = shift;
    my $userid = shift;
    my $full   = shift;
    my $issue  = shift;

    $self -> clear_error();

    # Determine whether the user can access the newsletter. If this
    # returns undef or a filled in hashref, it can be returned.
    my $newsletter = $self -> get_user_newsletter($name, $userid);
    return undef if(!defined($newsletter));
    return $self -> self_error("User $userid does not have permission to access $name") if(!$newsletter -> {"id"});
    return $newsletter unless($full);

    # Caller has requested the full newsletter...
    # Fetch the list of dates the newsletter is released on (this is undef for manual releases)
    $newsletter -> {"issuedata"} -> {"dates"} = $self -> get_newsletter_datelist($newsletter, $self -> {"settings"} -> {"config"} -> {"newsletter:future_count"});

    # And work out the date range for articles that should appear in the selected issue
    my ($mindate, $maxdate, $usenext) = $self -> get_newsletter_daterange($newsletter, $newsletter -> {"issuedata"} -> {"dates"}, $issue);

    # store the information for later...
    $newsletter -> {"issuedata"} -> {"issue"}    = $issue;
    $newsletter -> {"issuedata"} -> {"ranges"} -> {"min"}     = $mindate;
    $newsletter -> {"issuedata"} -> {"ranges"} -> {"max"}     = $maxdate;
    $newsletter -> {"issuedata"} -> {"ranges"} -> {"usenext"} = $usenext;

    # Fetch the messages set for the current newsletter
    ($newsletter -> {"messages"}, $newsletter -> {"blocked"}) = $self -> get_newsletter_messages($newsletter -> {"id"}, $userid, $usenext, $mindate, $maxdate);

    # load the template config
    $newsletter -> {"template"} = $self -> _load_template_config($newsletter -> {"template"})
        or return undef;

    return $newsletter;
}


## @method $ active_newsletter($newsname, $userid)
# Obtain the data for the active newsletter. If no ID is provided, or the user
# does not have schedule access to the newsletter or any of its sections, this
# will choose the first newsletter the user has schedule access to (in
# alphabetical order) and return the data for that.
#
# @param newsname The name of the active newsletter.
# @param userid   The ID of the user fetching the newsletter data.
# @return A reference to a hash containing the newsletter data to use as the active newsletter.
sub active_newsletter {
    my $self     = shift;
    my $newsname = shift;
    my $userid   = shift;

    $self -> clear_error();

    # Determine whether the user can access the newsletter. If this
    # returns undef or a filled in hashref, it can be returned.
    my $newsletter = $self -> get_user_newsletter($newsname, $userid);
    return $newsletter if(!defined($newsletter) || $newsletter -> {"id"});

    # Get here and the user does not have access to the requested newsletter. Find the
    # first newsletter the user does have access to.
    my $newsh = $self -> {"dbh"} -> prepare("SELECT `name`
                                             FROM `".$self -> {"settings"} -> {"database"} -> {"schedules"}."`
                                             ORDER BY `name`");
    $newsh -> execute()
        or return $self -> self_error("Unable to execute schedule query: ".$self -> {"dbh"} -> errstr);

    while(my $row = $newsh -> fetchrow_arrayref()) {
        # check the user's access to the newsletter or its sections
        $newsletter = $self -> get_user_newsletter($row -> [0], $userid);
        return $newsletter if(!defined($newsletter) || $newsletter -> {"id"});
    }

    return $self -> self_error("User does not have any access to any newsletters");
}


## @method $ get_user_newsletter($newsname, $userid)
# Determine whether the user has schedule access to the specified
# newsletter, or one of the sections within the newsletter.
#
# @param newsname The ID of the newsletter to fetch
# @param userid The Id of the user requesting access.
# @return A reference to a hash containing the newsletter on success,
#         a reference to an empty hash if the user does not have access,
#         undef on error.
sub get_user_newsletter {
    my $self     = shift;
    my $newsname = shift;
    my $userid   = shift;

    $self -> clear_error();

    # Try to locate the requested schedule
    my $schedh = $self -> {"dbh"} -> prepare("SELECT *
                                              FROM `".$self -> {"settings"} -> {"database"} -> {"schedules"}."`
                                              WHERE `name` LIKE ?");
    $schedh -> execute($newsname)
        or return $self -> self_error("Unable to execute newsletter query: ".$self -> {"dbh"} -> errstr);

    # If the newsletter information has been found, determine whether the user has schedule access to
    # it, or a section inside it
    my $newsletter = $schedh -> fetchrow_hashref();
    if($newsletter) {
        # simple case: user has schedule access to the newsletter and all sections
        # This needs to handle access with no user - note that this is explicitly undef userid NOT simply !$userid
        # the latter could come from a faulty session, the former can only happen via explicit invocation.
        return $newsletter
            if(!defined($userid) ||
               $self -> {"roles"} -> user_has_capability($newsletter -> {"metadata_id"}, $userid, "newsletter.schedule") ||
               $self -> {"roles"} -> user_has_capability($newsletter -> {"metadata_id"}, $userid, "newsletter.layout"));

        # user doesn't have simple access, check access to sections of this newsletter
        my $secth = $self -> {"dbh"} -> prepare("SELECT `metadata_id`
                                                 FROM `".$self -> {"settings"} -> {"database"} -> {"schedule_sections"}."`
                                                 WHERE `schedule_id` = ?");
        $secth -> execute($newsletter -> {"id"})
            or return $self -> self_error("Unable to execute section query: ".$self -> {"dbh"} -> errstr);

        while(my $section = $secth -> fetchrow_arrayref()) {
            # If the user has schedule capability on the section, they can access the newsletter
            return $newsletter
                if($self -> {"roles"} -> user_has_capability($section -> [0], $userid, "newsletter.schedule") ||
                   $self -> {"roles"} -> user_has_capability($section -> [0], $userid, "newsletter.layout"));
        }
    }

    return {};
}


## @method $ get_newsletter_datelist($newsletter, $count)
# Given a newsletter and an issue count, produce a hash describing the
# days on which the newsletter will be generated. If the newsletter is
# a manual release newsletter, this returns undef.
#
# @param newsletter A reference to a hash containing the newsletter data.
# @param count      The number of issues to generate dates for
# @return a reference to a hash containing the newsletter date list
#         in the form { "YYYY" => { "MM" => [ DD, DD, DD], "MM" => [ DD, DD, DD] }, etc}
#         or undef
sub get_newsletter_datelist {
    my $self       = shift;
    my $newsletter = shift;
    my $count      = shift;

    return undef unless($newsletter -> {"schedule"});
    my $lastrun = $newsletter -> {"last_release"} || time();

    my $values = undef;
    my $cron  = DateTime::Event::Cron -> from_cron($newsletter -> {"schedule"});
    my $start = DateTime -> from_epoch(epoch => $lastrun);

    my $prev = $cron -> previous($start);
    my $late = 0;

    # check whether the last release went out, if not go back to it.
    if(!$newsletter -> {"last_release"} || $newsletter -> {"last_release"} < $prev -> epoch()) {
        $start = $cron -> previous($prev);
        $late = 1;
    }

    # iterate over the requested cron runs
    my $iter = $cron -> iterator(after => $start);
    for(my $i = 0; $i < $count; ++$i) {
        my $next = $iter -> next;
        push(@{$values -> {"hashed"} -> {$next -> year} -> {$next -> month}}, $next -> day);
        push(@{$values -> {"dates"}}, {"year"  => $next -> year,
                                       "month" => $next -> month,
                                       "day"   => $next -> day,
                                       "epoch" => $next -> epoch,
                                       "late"  => (!$i && $late)});
    }

    return $values;
}


## @method $ get_newsletter_datelist_json($newsletter, $count)
# Fetch the list of newsletter release dates as a json string. This does
# the same job as get_newsletter_datelist() except that it returns the
# newsletter release day information as a JSON-encoded string rather
# than a reference to a hash.
#
# @param newsletter A reference to a hash containing the newsletter data.
# @param count      The number of issues to generate dates for
# @return A string containing the JSON encoded information about the release
#         dates. If th enewsletter is manual release, this returns an
#         empty string.
sub get_newsletter_datelist_json {
    my $self       = shift;
    my $newsletter = shift;
    my $count      = shift;

    my $data = $self -> get_newsletter_datelist($newsletter, $count);
    return "" unless($data);

    return encode_json($data -> {"hashed"});
}


## @method @ get_newsletter_daterange($newsletter, $issue)
# Determine the date range for a given newsletter issue. This attempts
# to work out, based on the schedule set in the specified newsletter
# and an optional start date, when the current issue will be released, and
# when the previous issue should have been released.
#
# @param newsletter A reference to a hash containing the newsletter data.
# @param issue      A reference to an array containing the issue year, month, and day.
# @return An array of two values: the previous issue release date, and
#         the next issue release date, both as unix timestamps. If the
#         newsletter is a manual release, this returns the date of the last
#         publication, the current date, and a true value to indicate
#         that articles marked 'next' should be used.
sub get_newsletter_daterange {
    my $self       = shift;
    my $newsletter = shift;
    my $dates      = shift;
    my $issue      = shift;

    if($newsletter -> {"schedule"}) {
        my $start = DateTime -> now(); # Start off with a fallback of now

        my $firstyear  = $dates -> {"dates"} -> [0] -> {"year"};
        my $firstmonth = $dates -> {"dates"} -> [0] -> {"month"};
        my $firstday   = $dates -> {"dates"} -> [0] -> {"day"};
        my $usenext    = 0;

        # If an issue day has been set, try to use it
        if($issue && scalar(@{$issue}) && $issue -> [0] && $issue -> [1] && $issue -> [2]) {
            $start = eval { DateTime -> new(year  => $issue -> [0],
                                            month => $issue -> [1],
                                            day   => $issue -> [2]) };
            $self -> {"logger"} -> die_log($self -> {"cgi"}, "Bad issue date specified") if($@);

            $usenext = ($issue -> [0] == $firstyear && $issue -> [1] == $firstmonth && $issue -> [2] == $firstday);
        } else {
            $start = eval { DateTime -> new(year  => $firstyear,
                                            month => $firstmonth,
                                            day   => $firstday) };
            $self -> {"logger"} -> die_log($self -> {"cgi"}, "Bad start day in dates data") if($@);
            $usenext = 1;
        }

        my $cron = DateTime::Event::Cron -> new($newsletter -> {"schedule"});
        my $next_time = $cron -> next($start);
        my $prev_time = $cron -> previous($next_time);

        # Override the previous date for the next release, capturing everything
        # that should be released since the last release.
        $prev_time = DateTime -> from_epoch(epoch => $newsletter -> {"last_release"})
            if($usenext);

        return ($prev_time -> epoch(), $next_time -> epoch(), $usenext);
    } else {
        # Get the most recent digest date
        my $digesth = $self -> {"dbh"} -> prepare("SELECT `generated`
                                                   FROM `".$self -> {"settings"} -> {"database"} -> {"digests"}."`
                                                   WHERE `schedule_id` = ?
                                                   ORDER BY `generated` DESC
                                                   LIMIT 1");
        $digesth -> execute($newsletter -> {"id"})
            or return $self -> self_error("Unable to fetch last digest date: ".$self -> {"dbh"} -> errstr);

        my $digest = $digesth -> fetchrow_arrayref();
        return ($digest ? $digest -> [0] : 0, time(), 1);
    }
}


## @method $ get_newsletter_issuedates($newsletter)
# given a schedule, determine when the next release will (or should have) happen,
# and when the one after that will be.
#
# @param newsletter A reference to a hash containing the newsletter data.
# @return A refrence to an array of hashes containing the issue dates on success,
#         undef if the newsletter is a maual release newsletter.
sub get_newsletter_issuedates {
    my $self       = shift;
    my $newsletter = shift;

    $self -> clear_error();

    my $data = $self -> get_newsletter_datelist($newsletter, 2)
        or return $self -> self_error("Attempt to fetch date list for manual release newsletter");

    my $result = [];
    foreach my $day (@{$data -> {"dates"}}) {
        push(@{$result}, {"late" => $day -> {"late"},
                          "timestamp" => $day -> {"epoch"}});
    }

    return $result;
}


## @method @ get_issuedate($article)
# Given an article, complete with section and schedule information included,
# determine when the article should appear in a newsletter. Note that this
# will only return values for articles associated with automatic newsletters.
#
# @param article A reference to the article to get the newsletter date for.
# @return The article release time, and a flag indicating whether the release
#         is late
sub get_issuedate {
    my $self    = shift;
    my $article = shift;

    return (undef, undef)
        unless($article -> {"section_data"} -> {"schedule"} -> {"schedule"});

    # first get the times of releases
    my $releases = $self -> get_newsletter_issuedates($article -> {"section_data"} -> {"schedule"});

    # next is easy - it's the first of the releases
    if($article -> {"release_mode"} eq "next") {
        return ($releases -> [0] -> {"timestamp"}, $releases -> [0] -> {"late"});

    } elsif($article -> {"release_mode"} eq "after") {

        # 'after' articles can fall into several places. Either it's some time before he first release
        # (in which case it is due to go out in it), or it is in a later release.
        # Next release check first...
        if($article -> {"release_time"} < $releases -> [0] -> {"timestamp"}) {
            return ($releases -> [0] -> {"timestamp"}, $releases -> [0] -> {"late"});

        # It's not in the next release, so work out which future one it's in
        } else {
            my $cron  = DateTime::Event::Cron -> new($article -> {"section_data"} -> {"schedule"} -> {"schedule"});
            my $issue = $cron -> next(DateTime -> from_epoch(epoch => $article -> {"release_time"}));

            return ($issue -> epoch, $issue -> epoch < time());
        }
    }
}


## @method $ late_release($newsletter)
# Determine whether the specified newsletter has not released an issue when
# it should have already done so. This checks to see whether the specified
# newsletter is late in esnding out an issue - manual release newsletters
# are never late, so this will always return false for them.
#
# @param newsletter Either a reference to a hash containing the newsletter
#                   to check, or the name of the newsletter.
# @return true if the newsletter is late, false if it is not, undef on error.
sub late_release {
    my $self       = shift;
    my $newsletter = shift;

    $self -> clear_error();

    # first get the newsletter - either using the newsletter passed,
    # or searching for it by name
    my $newsletter_data;
    if(ref($newsletter) eq "HASH") {
        $newsletter_data = $newsletter;
    } else {
        $newsletter_data = $self -> get_newsletter($newsletter)
        or return undef;
    }

    # manual release newsletters are never late
    return 0 unless($newsletter_data -> {"schedule"});

    # automatic releae newsletters can be, so find out when a release will
    # happen, or should have happend by
    my $releases = $self -> get_newsletter_issuedates($newsletter_data);

    # All we really care about is whether the first issue is late
    return $releases -> [0] -> {"late"};
}


## @method $ get_newsletter_messages($newsid, $userid, $getnext, $mindate, $maxdate, $fulltext)
# Fetch the messages for the newsletter that are available to be published
# within the date range specified.
#
# @param newsid   The ID of the newsletter to fetch messages for.
# @param userid   The ID of the user fetching messages. This is optional, and
#                 if provided each section hash will contain an "editable"
#                 key indicating whether the user has edit access. If 0 or undef,
#                 "editable" is always false.
# @param getnext  Include articles with the "next" status?
# @param mindate  Optional miminum unix timestamp articles can have to be included
#                 (inclusive). If 0 or undef, no minimum is used.
# @param maxdate  Optional maximum unix timestamp articles can have to be included
#                 (inclusive). If 0 or undef, no maximum is used (use with caution!)
# @param fulltext If set to true, the title, summary, and full article text are
#                 included in the messages, otherwise only the title and summary
#                 are included.
# @return A reference to an array of hashes containing the newsletter messages,
#         arranged by section, on success, undef on error.
sub get_newsletter_messages {
    my $self     = shift;
    my $newsid   = shift;
    my $userid   = shift;
    my $getnext  = shift;
    my $mindate  = shift;
    my $maxdate  = shift;
    my $fulltext = shift;

    $self -> clear_error();

    # First get all the sections, ordered by the order they appear in the
    # newsletter.
    my $secth = $self -> {"dbh"} -> prepare("SELECT *
                                             FROM `".$self -> {"settings"} -> {"database"} -> {"schedule_sections"}."`
                                             WHERE `schedule_id` = ?
                                             ORDER BY `sort_order`");
    $secth -> execute($newsid)
        or return $self -> self_error("Unable to execute section query: ".$self -> {"dbh"} -> errstr);

    my $sections = $secth -> fetchall_arrayref({})
        or return $self -> self_error("Unable to fetch results for section query");

    return $self -> self_error("No sections defined for newsletter $newsid")
        if(!scalar(@{$sections}));

    # Go through the sections, working out which ones the user can edit, and
    # fetching the messages for the sections
    my $blocked = 0;
    foreach my $section (@{$sections}) {
        # User can only even potentially edit if one is defined and non-zero.
        $section -> {"editable"} = $userid && $self -> {"roles"} -> user_has_capability($section -> {"metadata_id"}, $userid, "newsletter.layout");

        # Fetch the messages even if the user can't edit the section, so they can
        # see the content in context
        $section -> {"messages"} = $self -> _fetch_section_messages($newsid, $section -> {"id"}, $getnext, $mindate, $maxdate, $fulltext);

        $blocked = 1 if($section -> {"required"} && !scalar(@{$section -> {"messages"}}));
    }

    return ($sections, $blocked);
}


## @method $ get_newsletter_articledata($newsletter)
# Given a newsletter hash, fill in the feed, level, image, and other data
# to use when generating issues of the newsletter.
#
# @param newsletter A reference to a newsletter hash as obtained by get_newsletter()
# @return true if the newsletter has been updated to include the article
#         data, undef on error.
sub get_newsletter_articledata {
    my $self       = shift;
    my $newsletter = shift;

    $self -> clear_error();

    $newsletter -> {"article_levels"} = $self -> _fetch_newsletter_levels($newsletter -> {"id"})
        or return undef;

    $newsletter -> {"article_feeds"}  = $self -> _fetch_newsletter_feeds($newsletter -> {"id"})
        or return undef;

    $newsletter -> {"article_images"} = $self -> _fetch_newsletter_images($newsletter -> {"id"})
        or return undef;

    ($newsletter -> {"methods"}, $newsletter -> {"notify_matrix"}) = $self -> _fetch_newsletter_notifications($newsletter -> {"id"})
        or return undef;

    return 1;
}


## @method private $ reorder_articles_fromsortdata($sortdata, $userid)
# Update the order of articles within a newsletter based on the provided sort data.
#
# @param sortdata A reference to an array of sort directive entries. Each element should
#                 be a string of the form list-<schedule_id>-<section_id>_msg-<article_id>
# @param userid   The ID of the user reordering the articles.
# @return true on success, undef on error.
sub reorder_articles_fromsortdata {
    my $self     = shift;
    my $sortdata = shift;
    my $userid   = shift;

    $self -> clear_error();

    # Each entry in $sortdata should be of the form list-<schedule_id>-<section_id>_msg-<article_id>
    # This allows us to parse the sort data into a hash of sections, each value being an array of
    # article IDs in the section in the required order.
    my $sections;
    my $sid = 1;
    my $schedule_id;
    foreach my $row (@{$sortdata}) {
        my ($schedule, $section, $article) = $row =~ /^list-(\d+)-(\d+)_msg-(\d+)$/;

        # using straight ! is safe here; valid IDs are always >0
        $self -> self_error("Malformed data in provides sort data")
            if(!$schedule || !$section || !$article);

        $schedule_id = $schedule if(!$schedule_id);
        $sections -> {$section} -> {"order"} = $sid++ if(!$sections -> {$section} -> {"order"});

        push(@{$sections -> {$section} -> {"articles"}}, $article);
    }

    # Process the sections, reordering articles if allowed.
    foreach my $section_id (sort { $sections -> {$a} -> {"order"} <=> $sections -> {$b} -> {"order"} } keys(%{$sections})) {
        # Make sure the user has permission to do anything in the section
        my $section = $self -> get_section($section_id)
            or return undef;

        if($self -> {"roles"} -> user_has_capability($section -> {"metadata_id"}, $userid, "newsletter.layout")) {
            # User can edit the section, so set the order of the articles within it
            for(my $pos = 0; $pos < scalar(@{$sections -> {$section_id} -> {"articles"}}); ++$pos) {
                $self -> update_section_relation($sections -> {$section_id} -> {"articles"} -> [$pos], $schedule_id, $section_id, $pos + 1)
                    or return undef;
            }
        }
    }

    return 1;
}


## @method $ get_newsletter_contributors($newsid, $mintime, $maxtime)
# Get the list of contributors to the specified newsletter, and whether they have
# indicated that their content is ready for this release.
#
# @param newsid the ID of the newsletter to get the contributor data for.

# @return a refrence to an array of hashes of user and readiness data.
sub get_newsletter_contributors {
    my $self    = shift;
    my $newsid  = shift;
    my $mintime = shift;
    my $maxtime = shift;

    $self -> clear_error();

    # First find out which users can possibly contribute to the newsletter
    my $users = $self -> _fetch_newsletter_users($newsid)
        or return undef;

    # Get the list of users who say they're ready
    my $ready = $self -> _fetch_ready_users($newsid, $mintime, $maxtime)
        or return undef;

    # Merge the two sets of data, marking users as ready where appropriate
    foreach my $user (@{$ready}) {
        $users -> {$user} -> {"ready"} = 1;
    }

    my @userlist = keys(%{$users});
    if(scalar(@userlist)) {
        my $placeholders = "?".(",?" x (scalar(@userlist) - 1));

        # And pull in the user data
        my $userdatah = $self -> {"dbh"} -> prepare("SELECT `user_id`, `username`, `realname`, `email`
                                                     FROM `".$self -> {"settings"} -> {"database"} -> {"users"}."`
                                                     WHERE `user_id` IN ($placeholders)");
        $userdatah -> execute(@userlist)
            or return $self -> self_error("Unable to fetch user data: ".$self -> {"dbh"} -> errstr());

        while(my $user = $userdatah -> fetchrow_hashref()) {
            $users -> {$user -> {"user_id"}} -> {"name"}  = $user -> {"realname"} || $user -> {"username"};
            $users -> {$user -> {"user_id"}} -> {"email"} = $user -> {"email"};
        }
    }

    return $users;
}


## @method $ toggle_ready($newsid, $userid, $issuedate, $readytime)
# Toggle the indication of the specified user's readiness for the provided newsletter.
# note that this does not determine whether the user has access to the newsletter;
# that must have been determined before calling this function!
#
# @param newsid    The ID of the newsletter the user has finished contributing to.
# @param userid    The ID of the contributing user.
# @param issuedate Unix timestamp of the start of the issue. For manual
#                  newsletters this should be the second following the last issue date.
# @param readytime The timestamp to set for the user's readiness. This must not be
#                  less than issuedate!
# @return true on success, undef on error.
sub toggle_ready {
    my $self      = shift;
    my $newsid    = shift;
    my $userid    = shift;
    my $issuedate = shift;
    my $readytime = shift;

    # Try to delete the user's status. This should result in a non-zero row count
    # if the user had an old status row
    my $offh = $self -> {"dbh"} -> prepare("DELETE
                                            FROM `".$self -> {"settings"} -> {"database"} -> {"schedule_ready"}."`
                                            WHERE `schedule_id` = ?
                                            AND `user_id` = ?
                                            AND `issue_date` = ?");
    my $rows = $offh -> execute($newsid, $userid, $issuedate);
    return $self -> self_error("Unable to execute status removal query: ".$self -> {"dbh"} -> errstr) if(!$rows);

    # If the row count is non-zero, the user had a status removed so we don't
    # want to add it back here
    return 1 if($rows > 0);

    # Otherwise, add the new row
    my $addh = $self -> {"dbh"} -> prepare("INSERT INTO `".$self -> {"settings"} -> {"database"} -> {"schedule_ready"}."`
                                            (`schedule_id`, `user_id`, `issue_date`, `ready_at`)
                                            VALUES(?, ?, ?, ?)");
    $addh -> execute($newsid, $userid, $issuedate, $readytime)
        or return $self -> self_error("Failed to insert new readiness row: ".$self -> {"dbh"} -> errstr);

    return 1;
}


# ============================================================================
#  Digesting

## @method $ make_digest_from_newsletter($newsletter, $articleid, $article)
# Given a full newsletter (call get_newsletter() with $full set to true),
# create a new digest entry for it, set up the direst section mappings,
# and mark the articles as used.
#
# @param newsletter A reference to a hash containing the newsletter data,
#                   including full message data.
# @param articleid  The ID of the article the newsletter was published in
# @param article    A reference to the system article model.
# @return The ID of the new digest header on success, undef on error.
sub make_digest_from_newsletter {
    my $self       = shift;
    my $newsletter = shift;
    my $articleid  = shift;
    my $article    = shift;

    $self -> clear_error();

    my $digestid = $self -> _create_digest($newsletter -> {"id"}, $articleid)
        or return undef;

    my $sectionh = $self -> {"dbh"} -> prepare("INSERT INTO `".$self -> {"settings"} -> {"database"} -> {"articledigest"}."`
                                                (`article_id`, `digest_id`, `section_id`, `sort_order`)
                                                VALUES(?, ?, ?, ?)");
    # Go through each section, recording each article/section relation
    foreach my $section (@{$newsletter -> {"messages"}}) {
        foreach my $message (@{$section -> {"messages"}}) {
            my $rows = $sectionh -> execute($message -> {"id"}, $digestid, $section -> {"id"}, $message -> {"sort_order"});
            return $self -> self_error("Unable to perform article digest for article $articleid digest $digestid: ". $self -> {"dbh"} -> errstr) if(!$rows);
            return $self -> self_error("Article digest for article $articleid digest $digestid failed, no rows inserted") if($rows eq "0E0");

            # Mark the article as used
            $article -> set_article_status($message -> {"id"}, "used", 0, 1)
                or return $self -> self_error("Article digesting failed: ".$article -> errstr());
        }
    }

    return $digestid;
}



## @method $ get_digest($id)
# Given a digest ID, fetch the data for the digest with that id.
#
# @param id The ID of the digest to fetch the data for.
# @return A reference to a hash containing the digest data on success,
#         undef on error or if the digest does not exist.
sub get_digest {
    my $self = shift;
    my $id   = shift;

    $self -> clear_error();

    my $digesth = $self -> {"dbh"} -> prepare("SELECT * FROM `".$self -> {"settings"} -> {"database"} -> {"digests"}."`
                                               WHERE `id` = ?");
    $digesth -> execute($id)
        or return $self -> self_error("Unable to execute digest lookup query: ".$self -> {"dbh"} -> errstr);

    return ($digesth -> fetchrow_hashref() || $self -> self_error("Request for non-existant digest $id"));
}


# ============================================================================
#  Relation control

## @method $ add_section_relation($articleid, $scheduleid, $sectionid, $sort_order)
# Create a relation between the specified article and the provided section of a schedule.
#
# @param articleid  The ID of the article to set up the relation for.
# @param scheduleid The ID of the schedule the article should be part of.
# @param sectionid  The ID of the section in the schedule to add the article to.
# @param sort_order The position in the section to add the article at. If this is
#                   omitted or zero, the article is added at the end of the section.
#                   Note that multiple articles may have the same sort_order, and
#                   no reordering of surrounding articles is done.
# @return true on success, undef on error.
sub add_section_relation {
    my $self       = shift;
    my $articleid  = shift;
    my $scheduleid = shift;
    my $sectionid  = shift;
    my $sort_order = shift;

    $self -> clear_error();

    # If there is no sort_order set, work out the next one.
    # NOTE: this is potentially vulnerable to atomicity violation problems: the
    # max value determined here could have changed by the time the code gets
    # to the insert. However, in this case, that's not a significant problem
    # as articles sharing sort_order values is safe (or at least non-calamitous)
    if(!$sort_order) {
        my $posh = $self -> {"dbh"} -> prepare("SELECT MAX(`ss`.`sort_order`)
                                                FROM `".$self -> {"settings"} -> {"database"} -> {"articlesection"}."` AS `ss`,
                                                     `".$self -> {"settings"} -> {"database"} -> {"articles"}."` AS `a`
                                                WHERE `a`.`id` = `ss`.`article_id`
                                                AND `ss`.`schedule_id` = ?
                                                AND `ss`.`section_id` = ?
                                                AND (`a`.`release_mode`= 'next'
                                                     OR `a`.`release_mode` = 'after'
                                                     OR `a`.`release_mode` = 'nldraft')");
        $posh -> execute($scheduleid, $sectionid)
            or return $self -> self_error("Unable to perform article section sort_order lookup: ". $self -> {"dbh"} -> errstr);

        my $posrow = $posh -> fetchrow_arrayref();
        $sort_order = $posrow ? ($posrow -> [0] || 0) + 1 : 1;
    }

    # And do the insert
    my $secth = $self -> {"dbh"} -> prepare("INSERT INTO `".$self -> {"settings"} -> {"database"} -> {"articlesection"}."`
                                             (`article_id`, `schedule_id`, `section_id`, `sort_order`)
                                             VALUES(?, ?, ?, ?)");
    my $rows = $secth -> execute($articleid, $scheduleid, $sectionid, $sort_order);
    return $self -> self_error("Unable to perform article section relation insert: ". $self -> {"dbh"} -> errstr) if(!$rows);
    return $self -> self_error("Article section relation insert failed, no rows inserted") if($rows eq "0E0");

    return 1;
}


## @method $ update_section_relation($articleid, $scheduleid, $sectionid, $sort_order)
# Update the section and sort order of an article. This will not move the article to
# a new schedule, but it can move it to a different section within the schedule, and
# change its location within the section. All the arguments are required - including
# the sort order, unlike with add_section_relation() - and the section must be part
# of the specified section.
#
# @param articleid  The ID of the article to update the relation for.
# @param scheduleid The ID of the schedule the article is part of.
# @param sectionid  The ID of the section in the schedule the article should be in.
# @param sort_order The position in the section to assign to the relation.
# @return true on success, undef on error.
sub update_section_relation {
    my $self       = shift;
    my $articleid  = shift;
    my $scheduleid = shift;
    my $sectionid  = shift;
    my $sort_order = shift;

    $self -> clear_error();

    my $moveh = $self -> {"dbh"} -> prepare("UPDATE `".$self -> {"settings"} -> {"database"} -> {"articlesection"}."`
                                             SET `section_id` = ?, `sort_order` = ?
                                             WHERE `article_id` = ?
                                             AND `schedule_id` = ?");
    $moveh -> execute($sectionid, $sort_order, $articleid, $scheduleid)
        or return $self -> self_error("Unable to perform article section relation update: ". $self -> {"dbh"} -> errstr);

    return 1;
}


# ============================================================================
#  Internal implementation

## @method $ _create_digest($scheduleid, $articleid)
# Create a new digest header for an article generated from the specified schedule.
#
# @param scheduleid The ID of the schedule the digest is for.
# @param articleid  The ID of the article the schedule was digested into.
# @return The ID of the new digest header on success, undef on error.
sub _create_digest {
    my $self       = shift;
    my $scheduleid = shift;
    my $articleid  = shift;

    $self -> clear_error();

    my $newh = $self -> {"dbh"} -> prepare("INSERT INTO `".$self -> {"settings"} -> {"database"} -> {"digests"}."`
                                            (`schedule_id`, `article_id`, `generated`)
                                            VALUES(?, ?, UNIX_TIMESTAMP())");
    my $rows = $newh -> execute($scheduleid, $articleid);
    return $self -> self_error("Unable to perform digest creation: ". $self -> {"dbh"} -> errstr) if(!$rows);
    return $self -> self_error("Digest creation failed, no rows inserted") if($rows eq "0E0");

    # Get the new ID
    return ($self -> {"dbh"} -> {"mysql_insertid"} || $self -> self_error("Unable to obtain id for new digest row"));
}


## @method private $ _fetch_section_messages($schedid, $secid, $getnext, $mindate, $maxdate, $fulltext)
# Fetch the messages that should be published in the specified section of a newsletter.
#
# @param schedid  The ID of the newsletter schedule to fetch messages for.
# @param secid    The ID of the section in the newsletter to fetch messages for.
# @param getnext  Include articles with the "next" status?
# @param mindate  Optional miminum unix timestamp articles can have to be included
#                 (inclusive). If 0 or undef, no minimum is used.
# @param maxdate  Optional maximum unix timestamp articles can have to be included
#                 (inclusive). If 0 or undef, no maximum is used (use with caution!)
# @param fulltext If set to true, the title, summary, and full article text are
#                 included in the messages, otherwise only the title and summary
#                 are included.
sub _fetch_section_messages {
    my $self     = shift;
    my $schedid  = shift;
    my $secid    = shift;
    my $getnext  = shift;
    my $mindate  = shift;
    my $maxdate  = shift;
    my $fulltext = shift;
    my $filter   = "";

    if($getnext) {
        $filter  = " AND (`a`.`release_mode` = 'next' OR (`a`.`release_mode` = 'after'";
    } else {
        $filter  = " AND (`a`.`release_mode` = 'after'";
    }

    $filter .= " AND `a`.`release_time` >= $mindate" if(defined($mindate) && $mindate =~ /^\d+$/);
    $filter .= " AND `a`.`release_time` <= $maxdate" if($maxdate && $maxdate =~ /^\d+$/);
    $filter .= ")";
    $filter .= ")" if($getnext);

    my $query = "SELECT `s`.`id` AS `mapid`,`a`.`id`, `a`.`title`, `a`.`summary`, `a`.`release_mode`, `a`.`release_time`, `s`.`sort_order`
                 FROM `".$self -> {"settings"} -> {"database"} -> {"articlesection"}."` AS `s`,
                      `".$self -> {"settings"} -> {"database"} -> {"articles"}."` AS `a`
                 WHERE `a`.`id` = `s`.`article_id`
                 AND `s`.`schedule_id` = ?
                 AND `s`.`section_id` = ?
                 $filter
                 ORDER BY `s`.`sort_order`";

    # Pull out the messages ordered as set by the user
    my $messh = $self -> {"dbh"} -> prepare($query);
    $messh -> execute($schedid, $secid)
        or return $self -> self_error("Unable to perform section article lookup: ". $self -> {"dbh"} -> errstr);

    return $messh -> fetchall_arrayref({});
}


## @method private $ _fetch_newsletter_feeds($newsid)
# Retrieve the list of feeds set up for the specified newsletter.
# This obtains a list of feeds the newsletter should be published in when
# issues are produced.
#
# @param newsid The ID of the newsletter to fetch the data for.
# @return A reference to an array of feed IDs on success, undef on error.
sub _fetch_newsletter_feeds {
    my $self   = shift;
    my $newsid = shift;

    $self -> clear_error();

    my $feedsh = $self -> {"dbh"} -> prepare("SELECT `feed_id`
                                              FROM `".$self -> {"settings"} -> {"database"} -> {"schedule_feeds"}."`
                                              WHERE `schedule_id` = ?");
    $feedsh -> execute($newsid)
        or return $self -> self_error("Unable to perform newsletter feed query: ".$self -> {"dbh"} -> errstr());

    my $feeds = [];
    while(my $feed = $feedsh -> fetchrow_arrayref()) {
        push(@{$feeds}, $feed -> [0]);
    }

    return $feeds;
}


## @method private $ _fetch_newsletter_levels($newsid)
# Fetch the level information for the specified newsletter. This fetches the list
# of levels the newsletter should be posted at when issues are generated.
#
# @param newsid The ID of the newsletter to fetch the data for.
# @return A reference to a hash containing the level data on success, undef on error.
sub _fetch_newsletter_levels {
    my $self   = shift;
    my $newsid = shift;

    $self -> clear_error();

    my $levelsh = $self -> {"dbh"} -> prepare("SELECT `l`.`level`
                                               FROM `".$self -> {"settings"} -> {"database"} -> {"levels"}."` AS `l`,
                                                    `".$self -> {"settings"} -> {"database"} -> {"schedule_levels"}."` AS `n`
                                               WHERE `l`.`id` = `n`.`level_id`
                                               AND `n`.`schedule_id` = ?");
    $levelsh -> execute($newsid)
        or return $self -> self_error("Unable to perform newsletter level query: ".$self -> {"dbh"} -> errstr());

    # the data from the database is not in a format that is suitable
    # to pass around with the newsletter, so some fiddling is needed
    my $result = {};
    while(my $row = $levelsh -> fetchrow_arrayref()) {
        $result -> {$row -> [0]} = 1;
    }

    return $result;
}


## @method private $ _fetch_newsletter_images($newsid)
# Fetch the image information for the specified newsletter. This fetches the list
# of images the newsletter should be posted at when issues are generated. Note
# that this is the top-level image information used in feed generation and
# auto-templating of articles, not the per-article image data set for articles
# in the newsletter.
#
# @param newsid The ID of the newsletter to fetch the data for.
# @return A reference to a hash containing the image data on success, undef on error.
sub _fetch_newsletter_images {
    my $self   = shift;
    my $newsid = shift;

    $self -> clear_error();

    my $imagesh = $self -> {"dbh"} -> prepare("SELECT `position`, `image_id`
                                               FROM `".$self -> {"settings"} -> {"database"} -> {"schedule_images"}."`
                                               WHERE `schedule_id` = ?");
    $imagesh -> execute($newsid)
        or return $self -> self_error("Unable to perform newsletter image query: ".$self -> {"dbh"} -> errstr());

    # The add_article() function expects images in a certain format of hash,
    # so build that up here
    my $images = {};
    while(my $image = $imagesh -> fetchrow_hashref()) {
        $images -> {$image -> {"position"}}  -> {"img"}  = $image -> {"image_id"};
        $images -> {$image -> {"position"}}  -> {"mode"} = "img";
    }

    return $images;
}


## @method private @ _fetch_newsletter_($newsid)
# Fetch the notification data for the specified newsletter. This fetches the list
# of recipients and notification methods associated with the specified newsletter.
#
# @param newsid The ID of the newsletter to fetch the data for.
# @return A reference to the method data hash, and a reference to the matrix data.
sub _fetch_newsletter_notifications {
    my $self   = shift;
    my $newsid = shift;
    my $methods;
    my $notify_matrix;

    # first fetch the list of recipientmethod mappings
    my $notifyh = $self -> {"dbh"} -> prepare("SELECT `m`.`name` AS `methodname`, `rm`.`method_id`, n.*
                                               FROM `".$self -> {"settings"} -> {"database"} -> {"schedule_notify"}."` AS `n`,
                                                    `".$self -> {"settings"} -> {"database"} -> {"notify_matrix"}."` AS `rm`,
                                                    `".$self -> {"settings"} -> {"database"} -> {"notify_methods"}."` AS `m`
                                               WHERE `m`.`id` = `rm`.`method_id`
                                               AND `rm`.`id` = `n`.`notify_recipient_method_id`
                                               AND `n`.`schedule_id` = ?");
    $notifyh -> execute($newsid)
        or return $self -> self_error("Unable to perform newsletter notification query: ".$self -> {"dbh"} -> errstr());

    while(my $notify = $notifyh -> fetchrow_hashref()) {
        # This gets filled in later...
        $methods -> {$notify -> {"methodname"}} = $notify -> {"method_id"};

        push(@{$notify_matrix -> {"used_methods"} -> {$notify -> {"methodname"}}}, $notify -> {"notify_recipient_method_id"});
    }

    # and now the data for the methods
    my $datah = $self -> {"dbh"} -> prepare("SELECT `data` FROM `".$self -> {"settings"} -> {"database"} -> {"schedule_methdata"}."`
                                             WHERE `schedule_id` = ?
                                             AND `method_id` = ?");
    foreach my $method (keys %{$methods}) {
        $datah -> execute($newsid, $methods -> {$method})
            or return $self -> self_error("Unable to perform newsletter method data query: ".$self -> {"dbh"} -> errstr());

        my $data = $datah -> fetchrow_arrayref();
        if($data) {
            # Split up data, expects format `name: value|name:|name:value|name:`
            my %settings = $data -> [0] =~ /(\w+):\s*([^|]*)\|?/g;

            $methods -> {$method} = \%settings;
        } else {
            $methods -> {$method} = undef;
        }
    }

    return ($methods, $notify_matrix);
}


## @method private $ _fetch_newsletter_users($newsid)
# Obtain a list of users who have access to contribute to the specified newsletter.
# This will generate a list of the users who have access to contribute articles
# to the specified newsletter, or a subsection of it.
#
# @param newsid The ID of the newsletter to fetch the user list for.
# @return A reference to an hash of user IDs on success, undef on error.
sub _fetch_newsletter_users {
    my $self = shift;
    my $newsid = shift;

    $self -> clear_error();

    # Fetch the list of sections for this newsletter.
    my $secth = $self -> {"dbh"} -> prepare("SELECT `metadata_id`
                                             FROM `".$self -> {"settings"} -> {"database"} -> {"schedule_sections"}."`
                                             WHERE `schedule_id` = ?");
    $secth -> execute($newsid)
        or return $self -> self_error("Unable to execute section query: ".$self -> {"dbh"} -> errstr);

    my $userhash = {};
    while(my $section = $secth -> fetchrow_arrayref()) {
        my $users = $self -> {"roles"} -> get_role_users($section -> [0], $self -> {"defined_roles"}, 1)
            or return $self -> self_error("Role lookup error: ".$self -> {"roles"} -> errstr());

        # We only need to mark the user as being a contributor in some fashion here.
        foreach my $user (keys(%{$users})) {
            $userhash -> {$user} -> {"ready"} = 0; # store zeros as the default to show a user can contribute but may not be ready
        }
    }

    my @userlist = keys(%{$userhash});

    return $self -> self_error("No users have access to newsletter $newsid!")
        if(!scalar(@userlist));

    return $userhash;
}


## @method private $ _fetch_ready_users($newsid, $mintime, $maxtime)
# Fetch the list of users who say they are done contributing to the specified
# newsletter for the given time.
#
# @param newsid  The ID of the newsletter to fetch ready users for.
# @param mintime The minimum ready time to include in the result (inclusive).
#                If not set, all ready entries since the beginning are included.
# @param maxtime The maximum ready time to include in the result (inclusive).
#                if not set, all ready entries from mintime on are included.
# @return A reference to an array of ready user IDs on success (which may be
#         an empty array!), undef on error.
sub _fetch_ready_users {
    my $self    = shift;
    my $newsid  = shift;
    my $mintime = shift;
    my $maxtime = shift;

    $self -> clear_error();

    my @params  = ($newsid);
    my $filters = "";
    if($mintime) {
        push(@params, $mintime);
        $filters .= " AND `ready_at` >= ?";
    }

    if($maxtime) {
        push(@params, $maxtime);
        $filters .= " AND `ready_at` <= ?";
    }

    # Now that we have users, work out which ones have indicated they are ready
    my $readyh = $self -> {"dbh"} -> prepare("SELECT `user_id`
                                              FROM `".$self -> {"settings"} -> {"database"} -> {"schedule_ready"}."`
                                              WHERE `schedule_id` = ?
                                              $filters");
    $readyh -> execute(@params)
        or return $self -> self_error("Ready user lookup failed: ".$self -> {"dbh"} -> errstr);

    my @users = ();
    while(my $ready = $readyh -> fetchrow_arrayref()) {
        push(@users, $ready -> [0]);
    }

    return \@users;
}


## @method private $ _load_template_config($path)
# Load the configuration file for the newsletter template.
#
# @param path The template-base relative path to the directory containing the
#             theme config.xml file
# @return A reference to a hash containing the config on success, undef on error.
sub _load_template_config {
    my $self = shift;
    my $path = shift;

    $self -> clear_error();

    $path = path_join($self -> {"template"} -> {"basepath"}, $self -> {"template"} -> {"theme"}, $path, "config.xml");
    my $xml = eval { XMLin($path, SuppressEmpty => undef); };

    return $self -> self_error("Unable to load newsletter theme config: $@") if($@);

    # Convert base-relative template names to absolute
    foreach my $section (keys(%{$xml -> {"section"}})) {
        foreach my $tem (keys(%{$xml -> {"section"} -> {$section}})) {
            next unless($xml -> {"section"} -> {$section} -> {$tem});

            $xml -> {"section"} -> {$section} -> {$tem} = path_join($xml -> {"base"}, $xml -> {"section"} -> {$section} -> {$tem});
        }
    }

    $xml -> {"body"} = path_join($xml -> {"base"}, $xml -> {"body"});
    $xml -> {"head"} = path_join($xml -> {"base"}, $xml -> {"head"});

    return $xml;
}

1;
