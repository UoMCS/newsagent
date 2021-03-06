## @file
# This file contains the implementation of the bridge to the userdata databse.
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
package Newsagent::System::UserDataBridge;

use strict;
use base qw(Webperl::SystemModule); # This class extends the system module
use v5.12;
use Data::Dumper;

# ============================================================================
#  Constructor

## @cmethod $ new(%args)
# Create a new Matrix object to manage matrix interaction.
# The minimum values you need to provide are:
#
# * dbh       - The database handle to use for queries.
# * settings  - The system settings object
# * metadata  - The system Metadata object.
# * roles     - The system Roles object.
# * logger    - The system logger object.
#
# @param args A hash of key value pairs to initialise the object with.
# @return A new Matrix object, or undef if a problem occured.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = $class -> SUPER::new(@_)
        or return undef;

    $self -> connect()
        or return Webperl::SystemModule::set_error($self -> errstr());

    return $self;
}


# ============================================================================
#  Connect/disconnect code


## @method $ connect()
# Check whether a connection to the userdata database is currently available, and
# create one if it is not.
#
# @return true if the connection is available, undef on error.
sub connect {
    my $self = shift;

    return 1 if($self -> {"udata_dbh"} && $self -> {"udata_dbh"} -> ping());

    $self -> clear_error();

    $self -> {"udata_dbh"} = DBI->connect($self -> {"settings"} -> {"userdata"} -> {"database"},
                                          $self -> {"settings"} -> {"userdata"} -> {"username"},
                                          $self -> {"settings"} -> {"userdata"} -> {"password"},
                                          { RaiseError => 0, AutoCommit => 1, mysql_enable_utf8 => 1, mysql_auto_reconnect => 1 })
        or return $self -> self_error("Unable to connect to userdata database: ".$DBI::errstr);

    return 1;
}



## @method $ disconnect()
# Check whether a connection to the userdata database is currently available, and
# disconnect from it if it is. This will also clean up the database handle reference
# in $self.
#
# @return true if the connection was closed (or didn't exist), undef on error.
sub disconnect {
    my $self = shift;

    # disconnect does nothing if there is no database handle
    return 1 if(!$self -> {"udata_dbh"});

    $self -> clear_error();

    # Hopefully this actually works!
    $self -> {"udata_dbh"} -> disconnect()
        or $self -> warn_log("Warning from disconnect: ".$self -> {"udata_dbh"} -> errstr);

    $self -> {"udata_dbh"} = undef;

    return 1;
}


# ============================================================================
#  Data access

## @method $ get_valid_years($as_options)
# Obtain a list of academic years for which there is user information in the userdata
# database.
#
# @param as_options If this is set to true, the reference returned by this function
#                   contains the year data in a format suitable for use as <select>
#                   options via Webperl::Template::build_optionlist().
# @return A reference to an array containing year data hashrefs on success, undef
#         on error.
sub get_valid_years {
    my $self       = shift;
    my $as_options = shift;

    $self -> clear_error();

    $self -> connect()
        or return undef;

    my $lookuph = $self -> {"udata_dbh"} -> prepare("SELECT DISTINCT y.*
                                                     FROM `".$self -> {"settings"} -> {"userdata"} -> {"user_years"}."` AS l,
                                                          `".$self -> {"settings"} -> {"userdata"} -> {"acyears"}."` AS y
                                                     WHERE `y`.`id` = `l`.`year_id`
						     AND `y`.`start_year` <= ?
                                                     ORDER BY `y`.`start_year` DESC");
    $lookuph -> execute($self -> {"settings"} -> {"Year"} -> {"current"})
        or return $self -> self_error("Unable to execute academic year lookup: ".$self -> {"udata_dbh"} -> errstr);

    my $rows = $lookuph -> fetchall_arrayref({})
        or return $self -> self_error("Error fetching rows from year lookup");

    # If the data should be returned as-is, do so.
    return $rows if(!$as_options);

    # Otherwise, convert to an options-friendly format

    my @yearlist = ();
    foreach my $year (@{$rows}) {
        push(@yearlist, { "value" => $year -> {"id"},
                          "name"  => $year -> {"start_year"}."/".$year -> {"end_year"}});
    }

    return \@yearlist;
}


## @method $ get_current_year()
# Fetch the current year from the usr data - assumes that the maximum year id found in the
# student year level table is the current year.
#
# @return The ID of the current year on success, undef on error.
sub get_current_year {
    my $self = shift;

    $self -> clear_error();
    $self -> connect()
        or return undef;

    my $lookuph = $self -> {"udata_dbh"} -> prepare("SELECT `id`
                                                     FROM `".$self -> {"settings"} -> {"userdata"} -> {"acyears"}."`
                                                     WHERE `start_year` = ?");
    $lookuph -> execute($self -> {"settings"} -> {"Year"} -> {"current"})
        or return $self -> self_error("Unable to execute academic year lookup: ".$self -> {"udata_dbh"} -> errstr);

    my $row = $lookuph -> fetchrow_arrayref()
        or return $self -> self_error("Error fetching rows from year lookup");

    return $row -> [0];
}


## @method $ get_year_data($date)
# Given a date, attempt to locate the academic year the specified date falls in.
#
# @param date The date to locate the year for
# @return A reference to a hash containing the year data.
sub get_year_data {
    my $self = shift;
    my $date = shift;

    $self -> clear_error();

    my $query = $self -> {"udata_dbh"} -> prepare("SELECT * FROM `".$self -> {"settings"} -> {"userdata"} -> {"acyears"}."`
                                                   WHERE `start_semester1` < ?
                                                   ORDER BY `start_semester1` DESC
                                                   LIMIT 1");
    $query -> execute($date)
        or return $self -> self_error("Unable to execute academic year lookup: ".$self -> {"udata_dbh"} -> errstr);

    return ($query -> fetchrow_hashref() || $self -> self_error("Unable to find academic year for date $date"));
}


## @method $ get_year_range($year)
# Given a academic year start year, obtain the start and end datestamps
# for that year. Note that this includes the summer break in its range.
#
# @param year The academic year to fetch the start and end dates for.
# @return A reference to a hash containing the start and end dates for
#         the academic year.
sub get_year_range {
    my $self = shift;
    my $year = shift;

    $self -> clear_error();

    my $query = $self -> {"udata_dbh"} -> prepare("SELECT * FROM `".$self -> {"settings"} -> {"userdata"} -> {"acyears"}."`
                                                   WHERE `start_year` >= ?
                                                   ORDER BY `start_year` ASC
                                                   LIMIT 2");
    $query -> execute($year)
        or return $self -> self_error("Unable to execute academic year lookup: ".$self -> {"udata_dbh"} -> errstr);

    my $yeardata = $query -> fetchall_arrayref({});

    # No results, or the first one isn't the year requested? Give up.
    if(!scalar(@{$yeardata}) || $yeardata -> [0] -> {"start_year"} != $year) {
        return $self -> self_error("Unable to fetch year range data for year $year");

    # If we have data for the specified year and next, we can fix start and end points
    } elsif(scalar(@{$yeardata}) == 2) {
        return { start => $yeardata -> [0] -> {"start_semester1"},
                 end   => $yeardata -> [1] -> {"start_semester1"} - 1
        };

    # Only one result means we only have the current year, hopefully
    } elsif(scalar(@{$yeardata}) == 1) {

        # If the year is correct, use its start and end for now
        return { start => $yeardata -> [0] -> {"start_semester1"},
                 end   => $yeardata -> [0] -> {"end_semester2"}
        };

    } else {
        return $self -> self_error("This should not happen: get_year_range($year) broken");
    }
}


## @method private $ _add_multiparam($settings, $params, $table, $field, $type, $mode)
# Construct a potentially multi-parameter where clause based on the spcified settings.
# This creates a where clause that compares the specified table and field to each
# of the comma separated values in the settings.
#
# @param settings A comma separated string of values to use in the where clause.
# @param params   A reference to an array to store bind variable parameters in.
# @param table    The name of the table to apply there where clauses in.
# @param field    The name of the field in the table to perform the where on.
# @param type     The type of comparison to use, defaults to "=".
# @param mode     The where mode, defaults to "AND" (all values in the settings must
#                 match), or "OR" (at least one of the settings must match).
# @return A string containing the where clause text.
sub _add_multiparam {
    my $self      = shift;
    my $settings  = shift;
    my $params    = shift;
    my $table     = shift;
    my $field     = shift;
    my $type      = shift || "=";
    my $mode      = shift || "AND";

    my @entries = split(/,/, $settings);
    my @wheres = ();
    foreach my $entry (@entries) {
        push(@wheres, "`$table`.`$field` $type ?");
        push(@{$params}, $entry);
    }

    my $where = join(" $mode ", @wheres);

    return "AND ($where) ";
}


## @method $ _process_progplan($names, $yearid, $mode, $combine, $progplan, $dotables, $tables, $where, $params)
# Build a query fragment to include program or plan selection in user lookup.
#
# @param names    A string containing the program or plan names to use.
# @param yearid   An optional year id to restrict the plan or program selection to a year.
# @param mode     The mode to use when checking the action and reason. Should be "LIKE" or "NOT LIKE".
# @param combine  How to combine terms in the program or plan query. Should be "OR" or "AND"
# @param progplan Should be set to "plan" or "prog" depending on the type of query.
# @param dotables If true, include the table and initial where clauses.
# @param tables   A reference to a scalar containing the table string for the query.
# @param where    A reference to a acalar containing the where string for the query.
# @param params   A reference to the list of parameters used to fill in the where string.
sub _process_progplan {
    my $self = shift;
    my ($names, $yearid, $mode, $combine, $progplan, $dotables, $tables, $where, $params) = @_;

    if($dotables) {
        $$tables .= " JOIN `".$self -> {"settings"} -> {"userdata"} -> {"ac".$progplan."s"}."` AS `a$progplan`";
        $$tables .= " JOIN `".$self -> {"settings"} -> {"userdata"} -> {"user_".$progplan."s"}."` AS `u$progplan`";

        $$where  .= "AND" if($where);
        $$where  .= " `u$progplan`.`student_id` = `u`.`user_id` AND `a$progplan`.`id` = `u$progplan`.`".$progplan."_id` ";
        $$where  .= "AND `u$progplan`.`active` = 1 "; # only include active records.
        if(defined($yearid)) {
            $$where .= "AND `u$progplan`.`year_id` = ? ";
            push(@{$params}, $yearid);
        }
    }

    $$where .= $self -> _add_multiparam($names, $params, "a$progplan", "name", $mode, $combine);
}


## @method private $ _process_progact($progacts, $yearid, $mode, $dotables, $tables, $where, $params)
# Build a query fragment to include program actions and reasons in the user lookup.
#
# @param progacts The comma separated list of ACTION:DATA elements.
# @param yearid   The id of the year to constrain the query to.
# @param mode     The mode to use when checking the action and reason. Should be "LIKE" or "NOT LIKE".
# @param dotables If true, include the table and initial where clauses.
# @param tables   A reference to a scalar containing the table string for the query.
# @param where    A reference to a acalar containing the where string for the query.
# @param params   A reference to the list of parameters used to fill in the where string.
# @return true if the table and where strings were updated, false otherwise.
sub _process_progact {
    my $self     = shift;
    my ($progacts, $yearid, $mode, $dotables, $tables, $where, $params) = @_;

    my @proglist = split(/,/, $progacts);

    my $added = 0;
    foreach my $progact (@proglist) {

        # If the action parses, include the condition in the query.
        my ($action, $reason) = $progact =~ /^(?:(\w+):)?(\w+)$/;
        if($reason) {
            # Add tables and join to the progact table at most once.
            if($dotables) {
                $$tables .= " JOIN `".$self -> {"settings"} -> {"userdata"} -> {"progact"}."` AS `pa`";

                $$where  .= "AND" if($where);
                $$where  .= " `pa`.`student_id` = `u`.`user_id` AND `pa`.`year_id` = ? ";
                push(@{$params}, $yearid);

                $dotables = 0;
            }

            my $clause = "";
            if($action) {
                $clause .= "`pa`.`action` $mode ?";
                push(@{$params}, $action);
            }

            if($reason) {
                $clause .= " AND " if($clause);
                $clause .= " `pa`.`reason` $mode ?";
                push(@{$params}, $reason);
            }

            $$where  .= " AND ($clause)";

            $added = 1;
        }
    }

    return $added;
}


## @method $ get_user_addresses($settings)
# Fetch an array of all user addresses that match the query controlled by the
# specified settings. The settings hash provided may contain:
#
# - `yearid`: the academic year to fetch students for (this should always be
#       specified.
# - `level`: academic level, seperate multiple levels with commas, supported values are:
#       0 = PGR, 1 = UG Year 1, 2 = UG Year 2, 3 = UG Year 3, 4 = UG Year 4, 6 = PGT
# - `plan`: A comma separated list of plan names to include (if
#           set, and a student is not on a listed programme, they are
#           not included in the list). This may include wildcards.
# - `exlplan`: A comma seperated list of plan names to exclude (if set,
#              students are included as long as they are not on the specified
#              plan(s))
# - `prog`: A comma separated list of programme names to include (if
#           set, and a student is not on a listed programme, they are
#           not included in the list). This may include wildcards.
# - `exlprog`: A comma seperated list of programme names to exclude (if set,
#              students are included as long as they are not on the specified
#              programmes(s))
# - `progact`: A program action and reason specified as progact=ACTION:REASON
#              Students must have the specified action and reason to be included.
# - `course`: A comma separated list of courses the student must be in. Note that
#             the student must be in all of the courses.
sub get_user_addresses {
    my $self     = shift;
    my $settings = shift;

    $self -> clear_error();

    my $tables  = '`'.$self -> {"settings"} -> {"userdata"} -> {"users"}.'` AS `u`';
    my @params = ();
    my $where  = "";

    # All students at a given level in a given year
    if(defined($settings -> {"level"}) && defined($settings -> {"yearid"})) {
        $tables .= " JOIN `".$self -> {"settings"} -> {"userdata"} -> {"user_years"}."` AS l";
        $where  .= "`u`.`user_id` = `l`.`student_id` AND `l`.`active` = 1 AND `l`.`year_id` = ? ";
        push(@params, $settings -> {"yearid"});

        $where .= $self -> _add_multiparam($settings -> {"level"}, \@params, "l", "level", '=', "OR")

    # All students in a given year
    } elsif(defined($settings -> {"yearid"})) {
        $tables .= " JOIN `".$self -> {"settings"} -> {"userdata"} -> {"user_years"}."` AS l";
        $where  .= "`u`.`user_id` = `l`.`student_id` AND `l`.`year_id` = ? ";
        push(@params, $settings -> {"yearid"});
    }

    # plan filtering, inclusive
    if(defined($settings -> {"plan"})) {
        $self -> _process_progplan($settings -> {"plan"}, $settings  -> {"yearid"}, "LIKE", "OR", "plan", 1,
                                   \$tables, \$where, \@params);

        # Allow for exclusion at the same time as inclusion.
        $self -> _process_progplan($settings -> {"exlplan"}, $settings  -> {"yearid"}, "NOT LIKE", "AND", "plan", 0,
                                   \$tables, \$where, \@params)
            if(defined($settings -> {"exlplan"}));

    } elsif(defined($settings -> {"exlplan"})) {
        $self -> _process_progplan($settings -> {"exlplan"}, $settings  -> {"yearid"}, "NOT LIKE", "AND", "plan", 1,
                                   \$tables, \$where, \@params)
    }

    if(defined($settings -> {"prog"})) {
        $self -> _process_progplan($settings -> {"prog"}, $settings  -> {"yearid"}, "LIKE", "OR", "prog", 1,
                                   \$tables, \$where, \@params);

        # Allow for exclusion at the same time as inclusion.
        $self -> _process_progplan($settings -> {"exlprog"}, $settings  -> {"yearid"}, "NOT LIKE", "AND", "prog", 0,
                                   \$tables, \$where, \@params)
            if(defined($settings -> {"exlprog"}));

    } elsif(defined($settings -> {"exlprog"})) {
        $self -> _process_progplan($settings -> {"exlprog"}, $settings  -> {"yearid"}, "NOT LIKE", "AND", "prog", 1,
                                   \$tables, \$where, \@params)
    }

    # progact should be of the form 'progact=ACTION:REASON'
    # Filtering on program action requires a current year ID
    if(defined($settings -> {"progact"}) && defined($settings -> {"yearid"})) {
        my $donetables = $self -> _process_progact($settings -> {"progact"}, $settings -> {"yearid"}, "LIKE", 1,
                                                   \$tables, \$where, \@params);

        # Allow for exclusion at the same time as inclusion.
        if(defined($settings -> {"exlprogact"})) {
            $self -> _process_progact($settings -> {"exlprogact"}, $settings -> {"yearid"}, "NOT LIKE", !$donetables,
                                      \$tables, \$where, \@params);
        }

    } elsif(defined($settings -> {"exlprogact"}) && defined($settings -> {"yearid"})) {
        $self -> _process_progact($settings -> {"exlprogact"}, $settings -> {"yearid"}, "NOT LIKE", 1,
                                  \$tables, \$where, \@params);
    }

    # Filtering on course requires a current year
    if(defined($settings -> {"course"}) && defined($settings -> {"yearid"})) {
        $tables .= ", `".$self -> {"settings"} -> {"userdata"} -> {"courses"}."` AS `c`";
        $tables .= ", `".$self -> {"settings"} -> {"userdata"} -> {"user_course"}."` AS `uc`";
        $where  .= "AND `uc`.`user_id` = `u`.`user_id` AND `c`.`id` = `uc`.`course_id` AND `uc`.`active` = 1 AND `uc`.`year_id` = ? ";
        push(@params, $settings -> {"yearid"});

        $where .= $self -> _add_multiparam($settings -> {"course"}, \@params, "c", "course_id", "LIKE", "OR");
    }

    # filter by user to 'remove' people from the list
    if(defined($settings -> {"exluomid"}) && scalar(@{$settings -> {"exluomid"}})) {
        $where .= "AND `u`.`uom_id` NOT IN (?".(",?" x (scalar(@{$settings -> {"exluomid"}}) - 1)).") ";

        push(@params, @{$settings -> {"exluomid"}});
    }

    $self -> connect()
        or return undef;

    my $query = "SELECT `u`.`email`, `xd`.`alt_email`
                 FROM $tables
                 LEFT JOIN `".$self -> {"settings"} -> {"userdata"} -> {"extradata"}."` AS `xd`
                     ON `u`.`user_id` = `xd`.`user_id`
                 WHERE $where";
    print STDERR "Query: $query\n".Dumper(\@params);

    my $queryh = $self -> {"udata_dbh"} -> prepare($query);
    $queryh -> execute(@params)
        or return $self -> self_error("Unable to execute student lookup: ".$self -> {"udata_dbh"} -> errstr);

    my %emails = ();
    while(my $row = $queryh -> fetchrow_arrayref()) {
        $emails{$row -> [0]} = 1
            if(!$settings -> {"alt_email"} && $row -> [0]);

        $emails{$row -> [1]} = 1
            if($settings -> {"alt_email"} && $row -> [1]);
    }

    my @unique = keys(%emails);
    print STDERR "Got ".scalar(@unique)." addresses.";
    return \@unique;
}

1;
