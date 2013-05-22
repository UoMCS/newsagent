# @file
# This file contains the implementation of the HTML query facility.
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
package Newsagent::Feed::HTML;

use strict;
use base qw(Newsagent::Feed); # This class extends the Newsagent::Feed class
use Newsagent::System::Article;
use Digest::MD5 qw(md5_hex);
use Webperl::Utils qw(trimspace path_join);
use v5.12;
use Data::Dumper;

# ============================================================================
#  Content generators

## @method void generate_feed()
# Generate an RSS feed of articles based on the filters specified by the user on
# the query string. Note that this does not return, and errors that occur inside
# are consumed silently - this is a design decision based on the fact that the
# feeds are going to be automatically aggregated, and errors getting through
# to the aggregators is likely to be an undesirable state of affairs.
sub generate_feed {
    my $self     = shift;
    my $settings = $self -> _validate_settings();

    my @pathinfo = $self -> {"cgi"} -> param("pathinfo");

    # obtain the feed mode, and force it to a known value
    my $mode = $pathinfo[0];
    $mode = "feed" unless($pathinfo[0] eq "compact" || $pathinfo[0] eq "full");

    # Any mode other than full forces no fulltext, full forces it on
    $settings -> {"fulltext"} = ($mode eq "full");

    # Compact format disables all images
    $settings -> {"images"}   = ($mode ne "compact");

    # Fetch the article(s) to output
    my $results = $self -> {"article"} -> get_feed_articles($settings);

    my $items   = "";
    my $maxdate = 0;
    foreach my $result (@{$results}) {
        # Keep track of the latest date (should be the first result, really)
        $maxdate = $result -> {"release_time"}
            if($result -> {"release_time"} > $maxdate);

        # The date can be needed in both the title and date fields.
        my $pubdate = $self -> {"template"} -> format_time($result -> {"release_time"}, $self -> {"timefmt"});

        # Generate the image urls
        my $images = {"leader" => "", "article" => "" };

        $images -> {"leader"} = path_join($self -> {"settings"} -> {"config"} -> {"Article:upload_image_url"},
                                          $result -> {"images"} -> [0] -> {"location"})
            if($settings -> {"images"} && $result -> {"images"} -> [0] -> {"location"} && $result -> {"images"} -> [0] -> {"location"} !~ /^http/);

        # Force default leader image if needed
        $images -> {"leader"} = path_join($self -> {"settings"} -> {"config"} -> {"Article:upload_image_url"},
                                          $self -> {"settings"} -> {"config"} -> {"HTML:default_image"})
            if($settings -> {"images"} && !$images -> {"leader"} && $self -> {"settings"} -> {"config"} -> {"HTML:default_image"});

        $images -> {"article"} = path_join($self -> {"settings"} -> {"config"} -> {"Article:upload_image_url"},
                                           $result -> {"images"} -> [1] -> {"location"})
            if($settings -> {"images"} && $result -> {"images"} -> [1] -> {"location"} && $result -> {"images"} -> [1] -> {"location"} !~ /^http/);

        # Wrap the images in html
        $images -> {"leader"} = $self -> {"template"} -> load_template("feeds/html/image.tem", {"***class***" => "leader",
                                                                                                "***url***"   => $images -> {"leader"},
                                                                                                "***title***" => $result -> {"title"}})
            if($images -> {"leader"});

        $images -> {"article"} = $self -> {"template"} -> load_template("feeds/html/image.tem", {"***class***" => "article",
                                                                                                 "***url***"   => $images -> {"article"},
                                                                                                 "***title***" => $result -> {"title"}})
            if($images -> {"article"});


        # Put the item together!
        $items .= $self -> {"template"} -> load_template("feeds/html/item-$mode.tem", {"***title***"       => $result -> {"title"} || $pubdate,
                                                                                       "***summary***"     => $result -> {"summary"},
                                                                                       "***leaderimg***"   => $images -> {"leader"},
                                                                                       "***articleimg***"  => $images -> {"article"},
                                                                                       "***site***"        => $result -> {"sitename"},
                                                                                       "***date***"        => $pubdate,
                                                                                       "***guid***"        => $result -> {"siteurl"}."?id=".$result -> {"id"},
                                                                                       "***link***"        => $result -> {"siteurl"}."?id=".$result -> {"id"},
                                                                                       "***email***"       => $result -> {"email"},
                                                                                       "***name***"        => $result -> {"realname"} || $result -> {"username"},
                                                                                       "***fulltext***"    => $result -> {"fulltext"},
                                                                                       "***gravhash***"    => md5_hex(lc(trimspace($result -> {"email"} || ""))),
                                                             });
    }

    # Put everything together in a channel to send back to the user.
    my $feed = $self -> {"template"} -> load_template("feeds/html/channel.tem", {"***title***"       => $self -> {"settings"} -> {"config"} -> {"RSS:title"},
                                                                                 "***description***" => $self -> {"settings"} -> {"config"} -> {"RSS:description"},
                                                                                 "***link***"        => path_join($self -> {"cgi"} -> url(-base => 1),
                                                                                                                  $self -> {"settings"} -> {"config"} -> {"scriptpath"}, "rss"),
                                                                                 "***lang***"        => "en",
                                                                                 "***now***"         => $self -> {"template"} -> format_time(time(), $self -> {"timefmt"}),
                                                                                 "***changed***"     => $self -> {"template"} -> format_time($maxdate, $self -> {"timefmt"}),
                                                                                 "***items***"       => $items,
                                                                                 "***extra***"       => ""});

    # Do not use the normal page generation process to send back the feed - that sends back
    # html, not xml. This sends the feed to the user, and then cleans up and shuts down the
    # script.
    print $self -> {"cgi"} -> header(-type => 'text/html',
                                     -charset => 'utf-8');
    print Encode::encode_utf8($feed);

    $self -> {"template"} -> set_module_obj(undef);
    $self -> {"messages"} -> set_module_obj(undef);
    $self -> {"system"} -> clear() if($self -> {"system"});
    $self -> {"session"} -> {"auth"} -> {"app"} -> set_system(undef) if($self -> {"session"} -> {"auth"} -> {"app"});

    $self -> {"dbh"} -> disconnect();
    $self -> {"logger"} -> end_log();

    exit;
}

1;
