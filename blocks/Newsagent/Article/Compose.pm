## @file
# This file contains the implementation of the article composition facility.
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
package Newsagent::Article::Compose;

use strict;
use experimental 'smartmatch';
use base qw(Newsagent::Article); # This class extends the Article block class
use v5.12;
use Newsagent::System::TellUs;
use Newsagent::System::Matrix;
use Webperl::Utils qw(is_defined_numeric);

# ============================================================================
#  Content generators

## @method private @ _generate_compose($args, $error)
# Generate the page content for a compose page.
#
# @param args  An optional reference to a hash containing defaults for the form fields.
# @param error An optional error message to display above the form if needed.
# @return Two strings, the first containing the page title, the second containing the
#         page content.
sub _generate_compose {
    my $self  = shift;
    my $args  = shift || { };
    my $error = shift;

    my $userid = $self -> {"session"} -> get_session_userid();

    # Get a list of available posting levels in the system (which may be more than the
    # user has access to - we don't care about that at this point)
    my $sys_levels = $self -> {"article"} -> get_all_levels();
    my $jslevels   = $self -> _build_levels_jsdata($sys_levels);
    my $levels     = $self -> _build_level_options($sys_levels, $args -> {"levels"});

    # Work out where the user is allowed to post to
    my $user_feeds = $self -> {"feed"} -> get_user_feeds($userid, $sys_levels);
    my $feeds      = $self -> _build_feedlist($user_feeds, $args -> {"feeds"});

    # Work out which levels the user has access to for each feed. This generates a
    # chunk of javascript to stick into the page to hide/show options and default-tick
    # them as appropriate.
    my $user_levels = $self -> {"article"} -> get_user_levels($user_feeds, $sys_levels, $userid);
    my $feed_levels = $self -> _build_feed_levels($user_levels, $args -> {"levels"});

    # Release timing options
    my $relops = $self -> {"template"} -> build_optionlist($self -> {"relops"}, $args -> {"release_mode"});
    my $format_release = $self -> {"template"} -> format_time($args -> {"release_time"}, "%d/%m/%Y %H:%M")
        if($args -> {"release_time"});

    # Which schedules and sections can the user post to?
    my $schedules  = $self -> {"schedule"} -> get_user_schedule_sections($userid);
    my $schedblock = $self -> {"template"} -> load_template("article/compose/schedule_noaccess.tem"); # default to 'none of them'
    if($schedules && scalar(keys(%{$schedules}))) {
        my $schedlist    = $self -> {"template"} -> build_optionlist($schedules -> {"_schedules"}, $args -> {"schedule"});
        my $schedmode    = $self -> {"template"} -> build_optionlist($self -> {"schedrelops"}, $args -> {"schedule_mode"});
        my $schedrelease = $self -> {"template"} -> format_time($args -> {"stimestamp"}, "%d/%m/%Y %H:%M")
            if($args -> {"stimestamp"});

        my $scheddata = "";
        my $nextdata;
        $args -> {"section"} = "" if(!$args -> {"section"});

        foreach my $id (sort(keys(%{$schedules}))) {
            next unless($id =~ /^id_/);

            if($schedules -> {$id} -> {"next_run"} -> [0]) {
                $nextdata = "";
                foreach my $nextrun (@{$schedules -> {$id} -> {"next_run"}}) {
                    $nextdata .= ", " if($nextdata);
                    $nextdata .= '{"time": "'.$self -> {"template"} -> format_time($nextrun -> {"timestamp"}).'",';
                    $nextdata .= '"late": '.($nextrun -> {"late"} ? "true" : "false").'}';
                }
            } else {
                $nextdata = '{"time": "'.$self -> {"template"} -> replace_langvar("COMPOSE_SHED_MANUAL").'"},'.
                            '{"time": "'.$self -> {"template"} -> replace_langvar("COMPOSE_SHED_MANUAL").'"}';
            }

            $scheddata .= '"id_'.$schedules -> {$id} -> {"schedule_name"}.'": { next: ['.$nextdata.'],';
            $scheddata .= '"sections": ['.join(",",
                                               map {
                                                   '{ "value": "'. $_ -> {"value"}.'", "name": "'.$_ -> {"name"}.'", "selected": '.($_ -> {"value"} eq $args -> {"section"} && $schedules -> {$id} -> {"schedule_name"} eq $args -> {"schedule"} ? 'true' : 'false').'}'
                                               } @{$schedules -> {$id} -> {"sections"}}).']},';
        }

        $schedblock = $self -> {"template"} -> load_template("article/compose/schedule.tem", {"***schedule***"          => $schedlist,
                                                                                              "***schedule_mode***"     => $schedmode,
                                                                                              "***schedule_date_fmt***" => $schedrelease,
                                                                                              "***stimestamp***"        => $args -> {"stimestamp"} || 0,
                                                                                              "***sort_order***"        => 0,
                                                                                              "***priority***"          => $args -> {"priority"} || 3,
                                                                                              "***scheduledata***"      => $scheddata,
                                                             });
    }

    # Image options
    my ($imagea_opts, $imagea_btn) = $self -> _build_image_options($args -> {"images"} -> {"a"}, 'icon');
    my ($imageb_opts, $imageb_btn) = $self -> _build_image_options($args -> {"images"} -> {"b"}, 'media');

    # Wrap the error in an error box, if needed.
    $error = $self -> {"template"} -> load_template("error/error_box.tem", {"***message***" => $error})
        if($error);

    # Build the notification options and their settings boxes
    my $matrix = $self -> {"module"} -> load_module("Newsagent::Notification::Matrix", "queue" => $self -> {"queue"});
    my $notifyblock = $matrix -> build_matrix($userid, $args -> {"notify_matrix"} -> {"enabled"}, $args -> {"notify_matrix"} -> {"year"}, $args -> {"notify_matrix"} -> {"notify_at"});

    my $notify_settings = "";
    my $userdata = $self -> {"session"} -> get_user_byid($userid);

    my $methods = $self -> {"queue"} -> get_methods();
    foreach my $method (keys(%{$methods})) {
        $notify_settings .= $methods -> {$method} -> generate_compose($args, $userdata);
    }

    # Determine whether the user expects to be prompted for confirmation
    my $noconfirm = $self -> {"session"} -> {"auth"} -> {"app"} -> get_user_setting($userid, "disable_confirm");
    $noconfirm = $noconfirm -> {"value"} || "0";

    # Default the summary inclusion
    $args -> {"full_summary"} = 1 if(!defined($args -> {"full_summary"}));

    # load a tellus message as the default text if appropriate
    my $msgid = is_defined_numeric($self -> {"cgi"}, "tellusid");
    if($msgid) {
        my $tellus = Newsagent::System::TellUs -> new(dbh      => $self -> {"dbh"},
                                                      settings => $self -> {"settings"},
                                                      logger   => $self -> {"logger"},
                                                      roles    => $self -> {"system"} -> {"roles"},
                                                      metadata => $self -> {"system"} -> {"metadata"});
        if($tellus) {
            my $message = $tellus -> get_message($msgid);

            # If the message is valid, and the user has manage permission on its queue, use it as the default text.
            $args -> {"article"} = $message -> {"message"}
                if($message && $self -> check_permission('tellus.manage', $message -> {"metadata_id"}));
        }
    }

    # permission-based access to image button
    my $ckeconfig = $self -> check_permission('freeimg') ? "image_open.js" : "basic_open.js";

    # Medialib height depends on whether the user can upload images.
    my $mlibheight = $self -> check_permission("upload") ? "582px" : "450px";

    my ($filelist, $attblock) = $self -> _build_files_block($args -> {"files"});

    # And generate the page title and content.
    return ($self -> {"template"} -> replace_langvar("COMPOSE_FORM_TITLE"),
            $self -> {"template"} -> load_template("article/compose/compose.tem", {"***errorbox***"         => $error,
                                                                                   "***form_url***"         => $self -> build_url(block => "compose", pathinfo => ["add"]),
                                                                                   "***title***"            => $args -> {"title"},
                                                                                   "***summary***"          => $args -> {"summary"},
                                                                                   "***article***"          => $args -> {"article"},
                                                                                   "***allowed_feeds***"    => $feeds,
                                                                                   "***stickymodes***"      => $self -> _build_feed_stickysupport($user_feeds),
                                                                                   "***levels***"           => $levels,
                                                                                   "***release_mode***"     => $relops,
                                                                                   "***release_date_fmt***" => $format_release,
                                                                                   "***rtimestamp***"       => $args -> {"release_time"},
                                                                                   "***imageaopts***"       => $imagea_opts,
                                                                                   "***imagebopts***"       => $imageb_opts,
                                                                                   "***imagea_btn***"       => $imagea_btn,
                                                                                   "***imageb_btn***"       => $imageb_btn,
                                                                                   "***imagea_url***"       => $args -> {"images"} -> {"a"} -> {"url"} || "https://",
                                                                                   "***imageb_url***"       => $args -> {"images"} -> {"b"} -> {"url"} || "https://",
                                                                                   "***imagea_id***"        => $args -> {"images"} -> {"a"} -> {"img"} || 0,
                                                                                   "***imageb_id***"        => $args -> {"images"} -> {"b"} -> {"img"} || 0,
                                                                                   "***relmode***"          => $args -> {"relmode"} || 0,
                                                                                   "***userlevels***"       => $feed_levels,
                                                                                   "***levellist***"        => $jslevels,
                                                                                   "***sticky_mode***"      => $self -> {"template"} -> build_optionlist($self -> {"stickyops"}, $args -> {"sticky"}),
                                                                                   "***batchstuff***"       => $schedblock,
                                                                                   "***notifystuff***"      => $notifyblock,
                                                                                   "***notifysettings***"   => $notify_settings,
                                                                                   "***disable_confirm***"  => $noconfirm,
                                                                                   "***preset***"           => $args -> {"preset"},
                                                                                   "***fullsummary***"      => $args -> {"full_summary"} ? 'checked="checked"' : '',
                                                                                   "***ckeconfig***"        => $ckeconfig,
                                                                                   "***loadcount***"        => $self -> {"settings"} -> {"config"} -> {"Media:fetch_count"},
                                                                                   "***initialcount***"     => $self -> {"settings"} -> {"config"} -> {"Media:initial_count"},
                                                                                   "***mlibheight***"       => $mlibheight,
                                                                                   "***files***"            => $filelist,
                                                                                   "***filedrag***"         => $attblock,
                                                   }));
}


## @method private @ _generate_success()
# Generate a success page to send to the user. This creates a message box telling the
# user that their article has been added - this is needed to ensure that users get a
# confirmation, but it isn't generated inside _add_article() or _validate_article() so
# that page refreshes don't submit multiple copies.
#
# @return The page title, content, and meta refresh strings.
sub _generate_success {
    my $self = shift;

    return ("{L_COMPOSE_ADDED_TITLE}",
            $self -> {"template"} -> message_box("{L_COMPOSE_ADDED_TITLE}",
                                                 "articleok",
                                                 "{L_COMPOSE_ADDED_SUMMARY}",
                                                 "{L_COMPOSE_ADDED_DESC}",
                                                 undef,
                                                 "messagecore",
                                                 [ {"message" => $self -> {"template"} -> replace_langvar("SITE_CONTINUE"),
                                                    "colour"  => "blue",
                                                    "action"  => "location.href='".$self -> build_url(block => "articles", pathinfo => [])."'"} ]),
            ""
        );
}


# ============================================================================
#  Addition functions

## @method private @ _add_article()
# Add an article to the system. This validates and processes the values submitted by
# the user in the compose form, and stores the result in the database.
#
# @return Three values: the page title, the content to show in the page, and the extra
#         css and javascript directives to place in the header.
sub _add_article {
    my $self  = shift;
    my $error = "";
    my $args  = {};

    ($error, $args) = $self -> _validate_article();
    return $self -> _generate_compose($args, $error);
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

    my $error = $self -> check_login();
    return $error if($error);

    # Exit with a permission error unless the user has permission to compose
    if(!$self -> check_permission("compose")) {
        $self -> log("error:compose:permission", "User does not have permission to compose articles");

        my $userbar = $self -> {"module"} -> load_module("Newsagent::Userbar");
        my $message = $self -> {"template"} -> message_box("{L_PERMISSION_FAILED_TITLE}",
                                                           "error",
                                                           "{L_PERMISSION_FAILED_SUMMARY}",
                                                           "{L_PERMISSION_COMPOSE_DESC}",
                                                           undef,
                                                           "errorcore",
                                                           [ {"message" => $self -> {"template"} -> replace_langvar("SITE_CONTINUE"),
                                                              "colour"  => "blue",
                                                              "action"  => "location.href='".$self -> build_url(block => "compose", pathinfo => [])."'"} ]);

        return $self -> {"template"} -> load_template("error/general.tem",
                                                      {"***title***"     => "{L_PERMISSION_FAILED_TITLE}",
                                                       "***message***"   => $message,
                                                       "***extrahead***" => "",
                                                       "***userbar***"   => $userbar -> block_display("{L_PERMISSION_FAILED_TITLE}"),
                                                      })
    }

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
        # Normal page operation.
        # ... handle operations here...

        if(!scalar(@pathinfo)) {
            ($title, $content, $extrahead) = $self -> _generate_compose();
        } else {
            given($pathinfo[0]) {
                when("add")      { ($title, $content, $extrahead) = $self -> _add_article(); }
                when("success")  { ($title, $content, $extrahead) = $self -> _generate_success(); }
                default {
                    ($title, $content, $extrahead) = $self -> _generate_compose();
                }
            }
        }

        $extrahead .= $self -> {"template"} -> load_template("article/compose/extrahead.tem");
        return $self -> generate_newsagent_page($title, $content, $extrahead, "compose");
    }
}

1;
