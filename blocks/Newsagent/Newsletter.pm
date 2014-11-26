# @file
# This file contains the implementation of the Newsletter base class.
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
package Newsagent::Newsletter;

use strict;
use base qw(Newsagent::Article); # This class extends the Newsagent Article class
use Webperl::Utils qw(trimspace path_join);
use Digest::MD5 qw(md5_hex);
use CSS::Inliner;
use v5.12;
use Data::Dumper;

# ============================================================================
#  Content support

## @method private $ _build_newsletter_article($article, $template)
# Given an article and a template, process the contents of the article into the
# provided template. This allows per-section templating of articles in
# newsletters and control over article layout.
#
# @param article  A reference to a hash cotnaining the article data.
# @param template The name of the template to use for the article.
# @return A string containing the templated article.
sub _build_newsletter_article {
    my $self     = shift;
    my $article  = shift;
    my $template = shift;

    # The date can be needed in both the title and date fields.
    my $pubdate = $self -> {"template"} -> format_time($article -> {"release_time"}, $self -> {"timefmt"});

    # Generate the image urls
    my @images;

    for(my $img = 0; $img < 2; ++$img) {
        next if(!$article -> {"images"} -> [$img] || !$article -> {"images"} -> [$img] -> {"location"});

        $images[$img] = $article -> {"images"} -> [$img] -> {"location"}
        if($article -> {"images"} -> [$img] -> {"location"});

        $images[$img] = path_join($self -> {"settings"} -> {"config"} -> {"Article:upload_image_url"},
                                  $images[$img])
            if($images[$img] && $images[$img] !~ /^http/);
    }

    # Wrap the images in html
    $images[0] = $self -> {"template"} -> load_template("newsletter/image.tem", {"***class***" => "leader",
                                                                                 "***url***"   => $images[0],
                                                                                 "***title***" => $article -> {"title"}})
        if($images[0]);

    $images[1] = $self -> {"template"} -> load_template("newsletter/image.tem", {"***class***" => "article",
                                                                                 "***url***"   => $images[1],
                                                                                 "***title***" => $article -> {"title"}})
        if($images[1]);

    $article -> {"article"} = $self -> cleanup_entities($article -> {"article"})
        if($article -> {"article"});

    return $self -> {"template"} -> load_template($template, { "***id***"          => $article -> {"id"},
                                                               "***title***"       => $article -> {"title"} || $pubdate,
                                                               "***summary***"     => $article -> {"summary"},
                                                               "***leaderimg***"   => $images[0],
                                                               "***articleimg***"  => $images[1],
                                                               "***email***"       => $article -> {"email"},
                                                               "***name***"        => $article -> {"realname"} || $article -> {"username"},
                                                               "***fulltext***"    => $article -> {"article"},
                                                               "***gravhash***"    => md5_hex(lc(trimspace($article -> {"email"} || ""))),
                                                  });
}


## @method @ build_newsletter($name, $issue, $userid)
# Generate the contents of the specified issue of a newsletter.
#
# @param name   The name of the newsletter to generate.
# @param issue  An optional reference to an array containing the year,
#               month, and day of the issue to generate.
# @param userid An optional userid, if specified the system will check
#               that the user has schedule access to the newsletter
#               or a section of it. If omitted, no checks are done.
# @return A string containing the templated newsletter, and a
#         reference to a hash containing the complete newsletter data.
sub build_newsletter {
    my $self   = shift;
    my $name   = shift;
    my $issue  = shift;
    my $userid = shift;
    my $content;

    # Fetch the newsletter row. If userid is not undef, this will
    # determine whether the user has access to the newsletter,
    # otherwise it's assumed to be an internal operation.
    my $newsletter = $self -> {"schedule"} -> get_newsletter($name, $userid, 1, $issue);

    # If a newsletter is selected, build the page
    if($newsletter) {
        my ($body, $menu)  = ("", "");
        foreach my $section (@{$newsletter -> {"messages"}}) {
            next unless(scalar(@{$section -> {"messages"}}) || $section -> {"required"} || $section -> {"empty_tem"});

            my $articles = "";
            foreach my $message (@{$section -> {"messages"}}) {
                my $article = $self -> {"article"} -> get_article($message -> {"id"});

                $articles .= $self -> _build_newsletter_article($article, $section -> {"article_tem"});
            }

            # If the section contains no articles, use the empty template.
            $articles = $self -> {"template"} -> load_template($section -> {"empty_tem"})
                if(!$articles && $section -> {"empty_tem"});

            # If it's still empty, and required, make it as such
            $articles = $self -> {"template"} -> load_template("newsletter/list/required-section.tem")
                if(!$articles && $section -> {"required"});

            # And add this section to the accumulating page
            $body .= $self -> {"template"} -> load_template($section -> {"template"}, {"***articles***" => $articles,
                                                                                       "***title***"    => $section -> {"name"},
                                                                                       "***id***"       => $section -> {"id"}});
            $menu .= $self -> {"template"} -> load_template(path_join($newsletter -> {"template"}, "section-menu-item.tem"), {"***title***"    => $section -> {"name"},
                                                                                                                              "***id***"       => $section -> {"id"}});
        }

        $content .= $self -> {"template"} -> load_template(path_join($newsletter -> {"template"}, "body.tem"), {"***name***"        => $newsletter -> {"name"},
                                                                                                                "***description***" => $newsletter -> {"description"},
                                                                                                                "***id***"          => $newsletter -> {"id"},
                                                                                                                "***body***"        => $body,
                                                                                                                "***menu***"        => $menu});
    }

    # If there is any newsletter content, convert any styles to inline
    if($content) {
        my $html = $self -> {"template"} -> load_template("newsletter/harness.tem", {"***header***" => $self -> {"template"} -> load_template(path_join($newsletter -> {"template"}, "extrahead.tem")),
                                                                                     "***body***"   => $content});

        my $inliner = new CSS::Inliner;
        $inliner -> read({html => $html});
        $content = $inliner -> inlinify();

        # Nuke the harness
        $content =~ s|^.*?<body>\s*(.*?)\s*</body>.*$|$1|s;
    }

    return ($content, $newsletter);
}


## @method $ publish_newsletter($$name, $issue, $userid)
# Generate the contents of the specified issue of a newsletter.
#
# @param name   The name of the newsletter to publish.
# @param issue  An optional reference to an array containing the year,
#               month, and day of the issue to publish.
# @param userid An optional userid, if specified the system will check
#               that the user has publish access to the newsletter. If
#               omitted, no checks are done.
# @return undef on success, otherwise an error string
sub publish_newsletter {
    my $self   = shift;
    my $name   = shift;
    my $issue  = shift;
    my $userid = shift;

    my ($content, $newsletter) = $self -> build_newsletter($name, $issue, $userid);

    if($newsletter) {
        return $self -> {"template"} -> replace_langvar("NEWSLETTER_NOPUBLISH")
            if($userid && !$self -> check_permission("newsletter.publish", $newsletter -> {"metadata_id"}, $userid));

        return $self -> {"template"} -> replace_langvar("NEWSLETTER_PUBLISHBLOCK")
            if($newsletter -> {"blocked"});

        # Fill in the article-specific fields
        $self -> {"schedule"} -> get_newsletter_articledata($newsletter);

        # content contains the newsletter text, add it as a new newsletter article
        my $article = { "title"         => $newsletter -> {"article_subject"},
                        "summary"       => $newsletter -> {"article_summary"},
                        "article"       => $content,
                        "release_mode"  => "visible",
                        "full_summary"  => 1,
                        "levels"        => $newsletter -> {"article_levels"},
                        "feeds"         => $newsletter -> {"article_feeds"},
                        "images"        => $newsletter -> {"article_images"},
                        "methods"       => $newsletter -> {"methods"},
                        "notify_matrix" => $newsletter -> {"notify_matrix"},
        };

        # finally need the year
        $article -> {"notify_matrix"} -> {"year"} = $self -> {"system"} -> {"userdata"} -> get_current_year()
            or return $self -> {"system"} -> {"userdata"} -> errstr();

        # Publish the newsletter as an article
        my $aid = $self -> {"article"} -> add_article($article, $userid, undef, 0)
            or return $self -> {"article"} -> errstr();

        $self -> log("newsletter", "Added newsletter issue article $aid");

        $self -> {"queue"} -> queue_notifications($aid, $article, $userid, 0, $article -> {"notify_matrix"} -> {"used_methods"})
            or return "Publication failed: ".$self -> {"queue"} -> errstr();

        $self -> log("newsletter", "Newsletter notifications queued");

        # And now go through digesting all the messages published above so they
        # won't show up in other newsletters.
        my $did = $self -> {"schedule"} -> make_digest_from_newsletter($newsletter, $aid, $self -> {"article"})
            or return $self -> {"schedule"} -> errstr();

        $self -> log("newsletter", "Newsletter issue $aid digested as $did");

        # oddly return undef for success!
        return undef;
    }

    return "Publication failed: ".$self -> {"schedule"} -> errstr();
}


1;
