
var rdate_picker;
var sdate_picker;
var feed_levels;

function date_control(datefield, tsfield, control) {
    var selVal = $(control).getSelected().get("value");
    var disabled = (selVal != 'timed' && selVal != 'after');

    $(datefield).set("disabled", disabled);

    // clear the contents if the field is disabled
    if(disabled) {
        $(datefield).set('value', '');
        $(tsfield).set('value', '');
    } else if(!$(tsfield).get('value')) {
        // Create a default date one day from now
        var defdate = new Date();
        defdate.setTime(defdate.getTime() + 86400000);

        $(tsfield).set('value', defdate.getTime() / 1000);
        rdate_picker.select(defdate);
    } else {
        var defdate = new Date($(tsfield).get('value') * 1000);
        rdate_picker.select(defdate);
    }
}


function limit_textfield(fieldid, counterid, charlimit) {
    var curlength = $(fieldid).get("value").length;

    if(curlength >= charlimit) {
        $(fieldid).set("value", $(fieldid).get("value").substring(0, charlimit));
        $(counterid).innerHTML = "0";
    } else {
        $(counterid).innerHTML = charlimit - curlength;
    }
}


function show_image_subopt(selid)
{
    var opts = $(selid).options;
    var sel  = $(selid).selectedIndex;
    var opt;

    for(opt = 0; opt < opts.length; ++opt) {
        var elem = $(selid + "_" + opts[opt].value);
        if(elem) {
            if(opt == sel) {
                elem.reveal();
            } else {
                elem.dissolve();
            }
        }
    }
}


function set_visible_levels()
{
    var feed = $('comp-feed').getSelected().get("value");

    Object.each(feed_levels[feed], function (value, key) {
                     var box = $('level-'+key);
                     if(box) {
                         if(value) {
                             $('level-'+key).disabled = 0;
                             $('forlevel-'+key).removeClass("disabled");
                         } else {
                             $('level-'+key).disabled = 1;
                             $('level-'+key).set('checked', false); /* force no check when disabled */
                             $('forlevel-'+key).addClass("disabled");
                         }
                     }
                 });
}


function cascade_levels(element)
{
    if(!element.get('checked')) return 0;

    var position = level_list.indexOf(element.value);

    for(var i = position + 1; i < level_list.length; ++i) {
        if($('level-'+level_list[i])) {
            $('level-'+level_list[i]).set('checked', true);
        }
    }
}


function set_schedule_sections()
{
    var sched_drop = $('comp-schedule');

    if(sched_drop) {
        var schedule = sched_drop.getSelected().get("value");

        $('schedule-next1').set('html', schedule_data['id_'+schedule]['next'][0]);
        $('schedule-next2').set('html', schedule_data['id_'+schedule]['next'][1]);

        $('comp-section').empty();

        schedule_data['id_'+schedule]['sections'].each(function (item, index) {
            $('comp-section').adopt(new Element('option', {'html': item.name, 'value': item.value}));
            if(item.selected) $('comp-section').selectedIndex = index;
        });
    }
}


function confirm_errors(summary, fulltext, levels)
{
    var errlist = new Element('ul');
    var errelem = new Element('div').adopt(
        new Element('p', { html: confirm_messages['errors'] }),
        errlist
    );

    if(!levels) {
        errlist.adopt(new Element('li', { html: confirm_messages['nolevels'] }));
    }

    if(!summary.length && !fulltext.length) {
        errlist.adopt(new Element('li', { html: confirm_messages['notext'] }));
    }

    return errelem;
}


function confirm_levels()
{
    var levellist = new Element('ul');
    var levelelem = new Element('div').adopt(
        new Element('p', { html: confirm_messages['levshow'] }),
        levellist
    );

    $$('input[name=level]:checked').each(
        function(element) {
            levellist.adopt(new Element('li', { html: confirm_messages['levels'][element.get('value')] }));
        }
    );

    return levelelem;
}


function enabled_notify()
{
    var enabled = { };
    var format = /^(\d+)-(\d+)$/;

    $$('input[name=matrix]:checked').each(
        function(element) {
            var value = element.get('value');
            var match = format.exec(value);

            if(match) {
                var titleElem = $$('li#recip-'+match[1]+' > div.recipient')[0];
                if(titleElem) {
                    var method = notify_methods[match[2]];
                    var name   = titleElem.get('title');

                    if(!enabled[method]) enabled[method] = new Array();
                    enabled[method].push(name);
                }
            }
        }
    );

    return enabled;
}


function confirm_notify()
{
    var notifyelem;
    var enabled = enabled_notify();

    if(enabled && Object.keys(enabled).length) {
        notifyelem = new Element('div');

        Object.each(enabled, function(value, key) {
                        notifyelem.adopt(new Element('dl').adopt(
                                             new Element('dt', { html: confirm_messages['notify']+" "+key+":" }),
                                             new Element('dd', { html: value.join(", ") })
                                         )
                                        );
                    });

    }
    return notifyelem;
}


function confirm_submit()
{
    if($('stopconfirm').get('value') == '1') {
        $('fullform').submit();
    } else {
        var summary  = $('comp-summ').get('value');
        var fulltext = CKEDITOR.instances['comp-desc'].getData();
        var levels   = $$('input[name=level]:checked').length;
        var buttons  = [ { title: confirm_messages['cancel'] , color: 'blue', event: function() { popbox.close(); popbox.footer.empty(); }} ];

        // The start of the body text is the same regardless of whether there are are any errors.
        var bodytext = new Element('div').adopt(
            // Side image for the confirm dialog
            new Element('img', { src: 'templates/default/images/confirm.png',
                                 styles: {  'width': 48,
                                           'height': 48,
                                            'float': 'right',
                                           'margin': '0em 0em 0.5em 1em'
                                         }
                               }),
            // Introduction message.
            new Element('p', { html: confirm_messages['intro'] }));

        // If at least one level has been specified, and either the summary or full text have been set,
        // the article is almost certainly going to be accepted by the system so show the "this is where
        // the message will appear" stuff and the confirm button.
        if(levels && (summary.length || fulltext.length)) {
            bodytext.adopt(
                confirm_levels(),
                confirm_notify(),
                new Element('hr')

            );
            // Inject a confirmation disable checkbox into the footer, it looks better there than in the body
            popbox.footer.adopt(new Element('label', { 'for': 'conf-suppress-cb',
                                                       'styles': { 'float': 'left' }
                                                     }).adopt(
                                                         new Element('input', { type: 'checkbox',
                                                                                id: 'conf-suppress-cb'
                                                                              }),
                                                         new Element('span', { html: confirm_messages['stop'] })
                                                     ));

            buttons = [ { title: confirm_messages['confirm'], color: 'blue', event: function() { if($('conf-suppress-cb').get('checked')) {
                                                                                                     $('stopconfirm').set('value', 1);
                                                                                                 }
                                                                                                 $('fullform').submit();
                                                                                               }
                        },
                        buttons[0] ];

        // Otherwise, the system will reject the article - produce errors to show to the user, and keep
        // the single 'cancel' button.
        } else {
            bodytext.adopt(confirm_errors(summary, fulltext, levels));
        }

        $('poptitle').set('text', confirm_messages['title']);
        $('popbody').empty().adopt(bodytext);
        popbox.setButtons(buttons);
        popbox.open();
    }
}


window.addEvent('domready', function() {
    Locale.use('en-GB');
    rdate_picker = new Picker.Date($('release_date'), { timePicker: true,
                                                        yearPicker: true,
                                                        positionOffset: {x: 5, y: 0},
                                                        pickerClass: 'datepicker_dashboard',
                                                        useFadeInOut: !Browser.ie,
                                                        onSelect: function(date) {
                                                            $('rtimestamp').set('value', date.format('%s'));
                                                        }
                                                      });
    $('comp-release').addEvent('change', function() { date_control('release_date', 'rtimestamp', 'comp-release'); });
    date_control('release_date', 'rtimestamp', 'comp-release');

    $('comp-summ').addEvent('keyup', function() { limit_textfield('comp-summ', 'sumchars', 240); });
    limit_textfield('comp-summ', 'sumchars', 240);

    $('imagea_mode').addEvent('change', function() { show_image_subopt('imagea_mode'); });
    show_image_subopt('imagea_mode');
    $('imageb_mode').addEvent('change', function() { show_image_subopt('imageb_mode'); });
    show_image_subopt('imageb_mode');

    $('comp-feed').addEvent('change', function() { set_visible_levels(); });

    if($('comp-schedule')) {
        sdate_picker = new Picker.Date($('schedule_date'), { timePicker: true,
                                                             yearPicker: true,
                                                             positionOffset: {x: 5, y: 0},
                                                             pickerClass: 'datepicker_dashboard',
                                                             useFadeInOut: !Browser.ie,
                                                             onSelect: function(date) {
                                                                 $('stimestamp').set('value', date.format('%s'));
                                                             }
                                                           });
        $('comp-schedule').addEvent('change', function() { set_schedule_sections(); });
        set_schedule_sections();

        $('comp-srelease').addEvent('change', function() { date_control('schedule_date', 'stimestamp', 'comp-srelease'); });
        date_control('schedule_date', 'stimestamp', 'comp-srelease');
    }

    $$('input[name=level]').addEvent('change', function(event) { cascade_levels(event.target); });

    $('submitarticle').addEvent('click', function() { confirm_submit(); });

});
