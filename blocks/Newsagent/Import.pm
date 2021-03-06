## @file
# This file contains the implementation of the article importer page.
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
package Newsagent::Import;

use strict;
use experimental qw(smartmatch);
use base qw(Newsagent); # This class extends the Newsagent block class
use v5.12;
use Data::Dumper;

# ============================================================================
#  Constructor

## @cmethod $ new(%args)
#
# @param args A hash of values to initialise the object with. See the Block docs
#             for more information.
# @return A reference to a new Newsagent::Import object on success, undef on error.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = $class -> SUPER::new(@_)
        or return undef;

    $self -> {"importer"} = $self -> {"module"} -> load_module("Newsagent::Importer")
        or return Webperl::SystemModule::set_error("Importer initialisation failed: ".$self -> {"module"} -> errstr());

    return $self;
}


# ============================================================================
#  Internal implementation

## @method private @ _run_import($source)
# Run the import process for the specified import source.
#
# @param source The shortname for the import source to run.
# @return Two strings: the page title, and the contents of the page.
sub _run_import {
    my $self   = shift;
    my $source = shift;

    # Run the import?
    if($self -> {"importer"} -> should_run($source)) {
        my $importer = $self -> {"importer"} -> load_importer($source);
        if($importer) {
            my $result = $importer -> import_articles();
            $self -> {"importer"} -> touch_importer($source);

            return ("Testing", $result ? "Imported" : $importer -> errstr());
        }
    } else {
        return ("Skipped", "Skipped import as importer does not need to run yet");
    }
    return ("error", $self -> {"importer"} -> errstr());
}


# ============================================================================
#  Interface functions

## @method $ page_display()
# Produce the string containing this block's full page content. This generates
# the compose page, including any errors or user feedback.
#
# @return The string containing this block's page content.
sub page_display {
    my $self = shift;
    my ($title, $content, $extrahead);

    # NOTE: no need to check login here, this module can be used without logging in.

    # Is this an API call, or a normal page operation?
    my $apiop = $self -> is_api_operation();
    if(defined($apiop)) {
        # API call - dispatch to appropriate handler.
        given($apiop) {
            default {
                return $self -> api_html_response($self -> api_errorhash('bad_op',
                                                                         $self -> {"template"} -> replace_langvar("API_BAD_OP")))
            }
        }
    } else {
        my @pathinfo = $self -> {"cgi"} -> multi_param('pathinfo');

        if($pathinfo[0]) {
            ($title, $content) = $self -> _run_import($pathinfo[0]);
        } else {
            ($title, $content) = ("Error", "No import module selected");
        }

        return $self -> generate_newsagent_page($title, $content, $extrahead);
    }
}

1;
