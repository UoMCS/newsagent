# @file
# This file contains the implementation of the base Importer class
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
# The importer class serves as the base of other source-specific importer
# classes capable of taking content from other services and adding it
# to Newsagent as standard newsagent articles.
package Newsagent::Importer;

use strict;
use base qw(Newsagent); # This class extends the Newsagent block class
use Newsagent::System::Feed;
use Newsagent::System::Article;
use v5.12;


# ============================================================================
#  Constructor

## @cmethod $ new(%args)
# Overloaded constructor for the importer facility, loads the System::Article model
# and other classes required to generate the importers.
#
# @param args A hash of values to initialise the object with. See the Block docs
#             for more information.
# @return A reference to a new Newsagent::Importer object on success, undef on error.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = $class -> SUPER::new("timefmt" => '%a, %d %b %Y %H:%M:%S %z',
                                        @_)
        or return undef;

    $self -> {"feed"} = Newsagent::System::Feed -> new(dbh      => $self -> {"dbh"},
                                                       settings => $self -> {"settings"},
                                                       logger   => $self -> {"logger"},
                                                       roles    => $self -> {"system"} -> {"roles"},
                                                       metadata => $self -> {"system"} -> {"metadata"})
        or return Webperl::SystemModule::set_error("Feed initialisation failed: ".$Webperl::SystemModule::errstr);

    $self -> {"article"} = Newsagent::System::Article -> new(feed     => $self -> {"feed"},
                                                             dbh      => $self -> {"dbh"},
                                                             settings => $self -> {"settings"},
                                                             logger   => $self -> {"logger"},
                                                             roles    => $self -> {"system"} -> {"roles"},
                                                             metadata => $self -> {"system"} -> {"metadata"})
        or return Webperl::SystemModule::set_error("Article initialisation failed: ".$SystemModule::errstr);

    return $self;
}


# ============================================================================
#  Importer loading

## @method $ load_importer($id)
# Load the importer with the specified ID. This will create an instance of an import
# module identified by the specified ID in the import_sources table.
#
# @param id The ID of the import source to create an importer for.
# @return A reference to an importer object on success, undef on error.
sub load_importer {
    my $self = shift;
    my $id   = shift;

    $self -> clear_error();

    # Fetch the importer data
    my $importdata = $self -> get_import_source($id)
        or return undef;

    my $importer = $self -> {"module"} -> load_module($importdata -> {"perl_module"}, "importer_id" => $id,
                                                                                      "importer_shortname" => $importdata -> {"shortname"},
                                                                                      "importer_args"      => $importdata -> {"args"})
        or return $self -> self_error("Unable to load import module '".$importdata -> {"name"}."': ".$self -> {"module"} -> errstr());

    return $importer;
}


# ============================================================================
#  Class support functions


## @method $ find_by_sourceid($sourceid)
# Determine whether an article already exists containing the data for the imported
# article with the specified import-specific id.
#
# @param sourceid   The ID of the article as it appears in the import.
# @return A reference to a hash containing the
sub find_by_sourceid {
    my $self       = shift;
    my $sourceid   = shift;

    $self -> clear_error();

    my $datah = $self -> {"dbh"} -> prepare("SELECT *
                                             FROM `".$self -> {"settings"} -> {"database"} -> {"import_meta"}."`
                                             WHERE `importer_id` = ?`
                                             AND `source_id` LIKE ?");
    my $datah -> execute($self -> {"importer_id"}, $sourceid)
        or return $self -> self_error("Unable to look up import metadata: ".$self -> {"dbh"} -> errstr());

    return $datah -> fetchrow_hashref() || 0;
}

1;
