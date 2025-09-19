# flexframe-0.1.tm
#
# flexframe - a ttk::frame-based responsive container megawidget (skeleton v0.1)
#
# Design notes (short):
# - The public creation command is available as the global "flexframe" for
#   ergonomic usage (so you write "flexframe .ff ...").
# - Internally all implementation and state live under the ::flexframe namespace.
# - Instance state is stored in a single dict variable ::flexframe::instances
#   (mapping widgetPath -> instanceDict). This keeps usage consistent and
#   avoids mixing arrays and dicts.
# - The real underlying widget is created as a normal ttk::frame at the
#   requested widget path (e.g. ".ff"). Immediately after creation we rename
#   the widget *command* to "<path>::_base" so we can safely create an
#   ensemble command at the original path name which dispatches public
#   subcommands while preserving a fallback that forwards unknown subcommands
#   to the original widget command.
#
# No usage of canvas. Only ttk::frame and basic geometry commands are used.
#
package require Tk
package provide flexframe 0.1

# ----------------------------------------------------------------------
# Namespace-level storage and defaults
# - ::flexframe::instances (dict): maps widgetPath -> instanceDict
# - default_options (dict): default widget options
#
# instanceDict keys:
#   frame         -> name of the original widget command (after rename), e.g. ".ff::_base"
#   container     -> widget path of the internal container where children are placed (e.g. ".ff.container")
#   options       -> dict of widget options (e.g. -orient, -autoscroll, ...)
#   children      -> list of child widget paths, in order
#   child_options -> dict mapping childPath -> dict of child-specific options (e.g. -sticky)
#   vscroll/hscroll -> placeholders (empty) for future scrollbar widget names
# ----------------------------------------------------------------------
namespace eval ::flexframe {
    # main instances dict (string containing a Tcl dict)
    variable instances ""

    # default options (a dict)
    variable default_options [dict create \
        -orient vertical \
        -autoscroll 1 \
        -minsize {} \
        -start nw \
        -sticky news \
        -ipad 0 \
    ]

    # Export the factory function name (we'll create a global alias named "flexframe")
    namespace export create
}

# ----------------------------------------------------------------------
# Public creation function (inside namespace). We then export a global alias
# so users can call "flexframe .ff -orient vertical".
#
# Creation flow:
# 1) Create real widget: ttk::frame $pathName
# 2) Rename the widget command to "$pathName::_base" (keeps the real widget)
# 3) Create inner container "$pathName.container" (child of the real widget)
# 4) Save an instanceDict into ::flexframe::instances
# 5) Create a namespace ensemble at $pathName that maps known subcommands
#    to ::flexframe::impl::* procedures. Each map entry bakes the instance
#    pathName so the implementation receives it as first arg.
# 6) Use -fallback to forward unknown subcommands to the original widget
#    command (the renamed "$pathName::_base").
# ----------------------------------------------------------------------
proc ::flexframe::create {pathName args} {
    variable instances
    variable default_options

    # sanity checks
    if {[winfo exists $pathName]} {
        return -code error "widget \"$pathName\" already exists"
    }

    # 1) create the real widget at the requested pathName
    ttk::frame $pathName

    # 2) rename the widget command so we can create an ensemble at $pathName
    set baseCmd "${pathName}::_base"
    if {[llength [info commands $baseCmd]] != 0} {
        # Very unlikely, but protect against clobbering an already-existing command.
        # This is conservative: fail early to avoid stealth overwrites.
        # Caller can choose another widget name.
        destroy $pathName
        return -code error "internal name conflict: $baseCmd already exists"
    }
    rename $pathName $baseCmd

    # 3) create internal container (child frame) that will hold the children
    set container "${pathName}.container"
    ttk::frame $container
    # make it fill the parent real widget for now (we'll control child placement)
    place $container -in $pathName -relx 0 -rely 0 -relwidth 1 -relheight 1

    # 4) build the instanceDict and store it in ::flexframe::instances
    set options $default_options               ;# copy defaults
    set children {}
    set child_options {}
    set instDict [dict create \
        frame $baseCmd \
        container $container \
        options $options \
        children $children \
        child_options $child_options \
        vscroll {} \
        hscroll {} \
    ]
    set instances [dict set $instances $pathName $instDict]

    # 5) create the ensemble mapping. Each mapped script has $pathName baked in,
    # so the impl procedures receive the instance path as first argument.
    set map [list \
        configure [list ::flexframe::impl::configure $pathName] \
        cget      [list ::flexframe::impl::cget $pathName] \
        add       [list ::flexframe::impl::add $pathName] \
        clear     [list ::flexframe::impl::clear $pathName] \
        children  [list ::flexframe::impl::children $pathName] \
        itemconfigure [list ::flexframe::impl::itemconfigure $pathName] \
    ]

    # 6) fallback forwards unknown subcommands to the original widget command
    #    (the renamed baseCmd). Note we escape "$args" so it will be evaluated at
    #    runtime by the ensemble.
    set fallbackScript "eval $baseCmd {*}\$args"

    namespace ensemble create -command $pathName -map $map \
        -unknown [list ::flexframe::impl::delegateToBase $pathName]

    # Bind configure of the real widget (pathName) to our relayout hook.
    # When the widget is resized, ::flexframe::impl::relayout will be called with pathName.
    bind $pathName <Configure> [list ::flexframe::impl::relayout $pathName]

    # If creation args were provided (e.g. -orient ...), apply them now
    if {[llength $args] > 0} {
        uplevel 1 [list $pathName configure] $args
    }

    return $pathName
}

# Create global alias 'flexframe' so usage is:  flexframe .ff -orient vertical
interp alias {} flexframe {} ::flexframe::create

# ----------------------------------------------------------------------
# Implementation namespace: actual code that handles commands for each instance.
# All implementation procedures receive the instance pathName as their
# first argument.
# ----------------------------------------------------------------------
namespace eval ::flexframe::impl {
    # Helper: verify instance exists and return its instanceDict
    proc _get_instance {pathName} {
        variable ::flexframe::instances
        if {![dict exists $::flexframe::instances $pathName]} {
            return -code error "no such flexframe instance \"$pathName\""
        }
        return [dict get $::flexframe::instances $pathName]
    }

    # Helper: save instanceDict back into ::flexframe::instances
    proc _set_instance {pathName instDict} {
        variable ::flexframe::instances
        set ::flexframe::instances [dict set $::flexframe::instances $pathName $instDict]
    }

    # configure: widget-style configure.
    # - No args: return list of option descriptors (each descriptor is a 5-element list:
    #   optionName dbName dbClass default currentValue) — minimal implementation.
    # - One arg (option): return descriptor for that option.
    # - Pairs: set option value(s).
    proc configure {pathName args} {
        variable ::flexframe::instances

        # fetch instance
        set inst [::flexframe::impl::_get_instance $pathName]
        set options [dict get $inst options]

        if {[llength $args] == 0} {
            # Return all options as option-descriptor lists
            set out {}
            foreach opt [dict keys $options] {
                set val [dict get $options $opt]
                lappend out [list $opt {} {} {} $val]
            }
            return $out
        } elseif {[llength $args] == 1} {
            set opt [lindex $args 0]
            if {![dict exists $options $opt]} {
                return -code error "unknown option \"$opt\""
            }
            set val [dict get $options $opt]
            return [list $opt {} {} {} $val]
        } else {
            # treat as pairs to set
            if {[expr {[llength $args] % 2}] != 0} {
                return -code error "configure expects option/value pairs"
            }
            for {set i 0} {$i < [llength $args]} {incr i 2} {
                set opt [lindex $args $i]
                set val [lindex $args [expr {$i+1}]]
                # accept any option name (flexible); validate later if needed
                set options [dict set $options $opt $val]
            }
            set inst [dict set $inst options $options]
            ::flexframe::impl::_set_instance $pathName $inst
            return {}
        }
    }

    # cget: return current value for option
    proc cget {pathName option} {
        set inst [::flexframe::impl::_get_instance $pathName]
        set options [dict get $inst options]
        if {![dict exists $options $option]} {
            return -code error "unknown option \"$option\""
        }
        return [dict get $options $option]
    }

    # children: return the list of child widget paths
    proc children {pathName} {
        set inst [::flexframe::impl::_get_instance $pathName]
        return [dict get $inst children]
    }

    # add: add an existing widget into the flexframe
    # Usage (after ensemble maps the instance):
    #   .ff add childPath ?index? ?-option1 value1 ...?
    #
    # The optional index can be "end" or an integer. Additional option/value pairs
    # are stored as child-specific options (e.g. -sticky).
    proc add {pathName args} {
        set argc [llength $args]
        if {$argc == 0} {
            return -code error "wrong # args: should be \"$pathName add childPath ?index? ?-option value ...?\""
        }

        set child [lindex $args 0]
        set rest [lrange $args 1 end]

        # parse optional index (if present as first of rest)
        set idx "end"
        set optpairs {}
        if {[llength $rest] > 0} {
            set first [lindex $rest 0]
            if {$first eq "end" || [string is integer -strict $first]} {
                set idx $first
                set optpairs [lrange $rest 1 end]
            } else {
                set optpairs $rest
            }
        }

        # verify child exists
        if {![winfo exists $child]} {
            return -code error "child widget \"$child\" does not exist"
        }

        # get instance
        set inst [::flexframe::impl::_get_instance $pathName]
        set children [dict get $inst children]

        # resolve index
        if {$idx eq "end"} {
            set insertIndex [llength $children]
        } else {
            set insertIndex $idx
            if {$insertIndex < 0} { set insertIndex 0 }
            if {$insertIndex > [llength $children]} { set insertIndex [llength $children] }
        }

        # insert child into children list
        set children [linsert $children $insertIndex $child]
        set inst [dict set $inst children $children]

        # store child-specific options (optional)
        set child_opts_dict {}
        if {[llength $optpairs] > 0} {
            if {[expr {[llength $optpairs] % 2}] != 0} {
                return -code error "child options must be option/value pairs"
            }
            for {set i 0} {$i < [llength $optpairs]} {incr i 2} {
                set k [lindex $optpairs $i]
                set v [lindex $optpairs [expr {$i+1}]]
                set child_opts_dict [dict set $child_opts_dict $k $v]
            }
        }

        # merge into the instance's child_options dict
        set all_child_opts [dict get $inst child_options]
        set all_child_opts [dict set $all_child_opts $child $child_opts_dict]
        set inst [dict set $inst child_options $all_child_opts]

        # reparent the child into the container (place at 0,0 for now).
        set container [dict get $inst container]
        # use place so we can later control exact position; relayout will update geometry.
        place $child -in $container -x 0 -y 0

        # save instance
        ::flexframe::impl::_set_instance $pathName $inst

        return $child
    }

    # clear: remove all children, or one at index (do not destroy children).
    # Usage:
    #   .ff clear            ;# remove all children from flexframe
    #   .ff clear <index>    ;# remove child at index (0-based)
    proc clear {pathName {index {}}} {
        set inst [::flexframe::impl::_get_instance $pathName]
        set children [dict get $inst children]

        if {$index eq {}} {
            # remove all children
            foreach c $children {
                # forget placement; do not destroy
                catch {place forget $c}
            }
            set children {}
            set inst [dict set $inst children $children]
            # also clear child_options
            set inst [dict set $inst child_options {}]
            ::flexframe::impl::_set_instance $pathName $inst
            return {}
        } else {
            if {![string is integer -strict $index]} {
                return -code error "Index must be an integer"
            }
            if {$index < 0 || $index >= [llength $children]} {
                return -code error "Index out of range"
            }
            set child [lindex $children $index]
            catch {place forget $child}
            set children [lreplace $children $index $index]
            set inst [dict set $inst children $children]
            # remove child options for this child if present
            set child_opts [dict get $inst child_options]
            if {[dict exists $child_opts $child]} {
                set child_opts [dict unset $child_opts $child]
                set inst [dict set $inst child_options $child_opts]
            }
            ::flexframe::impl::_set_instance $pathName $inst
            return {}
        }
    }

    # itemconfigure: get or set a child's specific options
    # usage:
    #   .ff itemconfigure 0           ;# returns descriptor for that item
    #   .ff itemconfigure .b2 -sticky n
    #   .ff itemconfigure 1 -sticky se
    proc itemconfigure {pathName itemId args} {
        set inst [::flexframe::impl::_get_instance $pathName]
        set children [dict get $inst children]
        set child_opts [dict get $inst child_options]

        # resolve itemId to childPath
        if {[string is integer -strict $itemId]} {
            set idx $itemId
            if {$idx < 0 || $idx >= [llength $children]} {
                return -code error "Index out of range"
            }
            set child [lindex $children $idx]
        } else {
            set child $itemId
            # verify the child is present
            if {![lsearch -exact $children $child] >= 0} {
                # present
            } elseif {[lsearch -exact $children $child] == -1} {
                return -code error "child \"$child\" is not in this flexframe"
            }
        }

        # get current config for the child
        if {[dict exists $child_opts $child]} {
            set cur [dict get $child_opts $child]
        } else {
            set cur {}
        }

        if {[llength $args] == 0} {
            # return a simple descriptor for -sticky only (for now)
            set stickyVal [dict get $cur -sticky]
            if {$stickyVal eq ""} { set stickyVal {} }
            return [list -sticky {} {} {} $stickyVal]
        } else {
            # set option/value pairs for this child
            if {[expr {[llength $args] % 2}] != 0} {
                return -code error "itemconfigure expects option/value pairs"
            }
            for {set i 0} {$i < [llength $args]} {incr i 2} {
                set k [lindex $args $i]
                set v [lindex $args [expr {$i+1}]]
                set cur [dict set $cur $k $v]
            }
            set child_opts [dict set $child_opts $child $cur]
            set inst [dict set $inst child_options $child_opts]
            ::flexframe::impl::_set_instance $pathName $inst
            return {}
        }
    }

    # relayout: placeholder called on <Configure> of the instance (will receive pathName).
    # Real layout algorithm will be implemented incrementally; for now it's a NO-OP.
    proc relayout {pathName} {
        # TODO: implement the layout algorithm that:
        # - reads current instance options (-orient, -wrap, -ipad, -start, -sticky,...)
        # - measures container size, children requested sizes
        # - computes rows/columns and places children accordingly (using place)
        # - create/show/hide scrollbars if -autoscroll is enabled and content exceeds size
        #
        # For now, do nothing (skeleton).
        return
    }
}
