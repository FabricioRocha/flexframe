# flexframe.tcl
#
# A Tcl/Tk "megawidget" implementing a responsive, grid-like container
# called "flexframe". Written using namespaces (not TclOO), and designed
# to be sourced into any namespace. After sourcing, create instances with
# `::flexframe::create path ?-option value ...?` which will define the
# composite widget command at `path` supporting the subcommands described
# in the man-style spec.
#
# Compatible with Tcl/Tk 8.6 and 9.0.
package require Tk

namespace eval [namespace current] {
    if {![info exists flexframe_loaded]} {
        variable flexframe_loaded 1

        # Base namespace for this module inside the current namespace.
        namespace eval flexframe {

            # Instance counter for unique instance namespaces
            variable _instCounter 0
            
            # mapping from widget path -> instance namespace
            variable path2ns
            array set path2ns {}
            
            # fully-qualified module namespace name (cached)
            variable _modns
            set _modns [namespace current]
            
            # global mapping for canvas item ids: key is "instNs|childPath" -> id
            variable itemsMap
            array set itemsMap {}
            
            variable lastAdded {}
            # module-level debug flag (0/1). Set to 1 to enable debug prints.
            variable debug 0

            # Helper debug printers: `dbg` for module-level messages, `idbg`
            # for instance-aware messages (checks instance cfg(-debug)).
            proc dbg {msg} {
                variable debug
                if {$debug} {puts $msg}
            }
            proc idbg {instNs msg} {
                variable debug
                if {$debug} {puts $msg; return}
                if {$instNs ne {}} {
                    if {[catch {namespace eval $instNs {set cfg(-debug)}} val]} {
                        return
                    }
                    if {$val} {puts $msg}
                }
            }


            # Helper accessors to interact with instance namespaces.
            # These centralize `namespace eval` usage and simplify the rest
            # of the code so it doesn't need to repeatedly call namespace eval.
            proc inst_get {instNs var} {
                # Execute 'set var' inside the instance namespace and return its value.
                return [namespace eval $instNs [list set $var]]
            }
            proc inst_set {instNs var val} {
                namespace eval $instNs [list set $var $val]
            }
            proc cfg_get {instNs key} {
                # Return the stored configuration value from the instance namespace.
                return [namespace eval $instNs [list set cfg($key)]]
            }
            proc cfg_set {instNs key val} {
                # Validate and normalize some well-known options here so callers
                # get immediate feedback when they set invalid values.
                set k $key
                set v $val
                switch -- $k {
                    -orient {
                        set vv [string tolower [string trim $v]]
                        if {$vv eq ""} {set vv "vertical"}
                        set c [string index $vv 0]
                        if {$c eq "v"} {set v "vertical"} elseif {$c eq "h"} {set v "horizontal"} else {error "invalid value for -orient: '$val' (expected v|vertical|h|horizontal)"}
                    }
                    -start {
                        set vv [string tolower [string trim $v]]
                        set allowed {nw ne sw se}
                        if {[lsearch -exact $allowed $vv] == -1} {error "invalid value for -start: '$val' (expected anchor like nw|ne|sw|se|n|s|e|w|center)"}
                        set v $vv
                    }
                    -autoscroll {
                        set vv [string tolower [string trim $v]]
                        if {$vv eq "1" || $vv eq "true"} {set v 1} elseif {$vv eq "0" || $vv eq "false"} {set v 0} else {error "invalid value for -autoscroll: '$val' (expected 0|1|true|false)"}
                    }
                    -debug {
                        set vv [string tolower [string trim $v]]
                        if {$vv eq "1" || $vv eq "true"} {set v 1} elseif {$vv eq "0" || $vv eq "false"} {set v 0} else {error "invalid value for -debug: '$val' (expected 0|1|true|false)"}
                    }
                    default {
                        # other options left permissive; validation may be done elsewhere
                    }
                }
                namespace eval $instNs [list set cfg($key) $v]
            }

            ################################################################
            # Utility procs
            ################################################################

            # _px: convert Tk length spec to pixels using winfo
            # ARGUMENTS: widget - any widget in the same app; sizeSpec - string
            # RETURN: integer pixels
            proc _px {widget sizeSpec} {
                # Use winfo to convert; Tk accepts things like 1c, 2m, 10
                # We'll use winfo pixels on the root window as a helper.
                # ARGUMENTS: widget - widget path used to evaluate screen metrics
                # RETURN: integer pixel count
                if {$sizeSpec eq ""} {return 0}
                # if numeric, return as integer
                if {[string is integer -strict $sizeSpec]} {return $sizeSpec}
                # else, use tk font measure trick via 'winfo' by constructing a
                # temporary window of requested size. Simpler: use 'winfo pixels'
                # which accepts strings.
                return [winfo pixels $widget $sizeSpec]
            }

            # _makeInstNs: create and return a unique namespace for a widget instance
            # ARGUMENTS: none
            # RETURN: namespace string
            proc _makeInstNs {} {
                variable _instCounter
                incr _instCounter
                return [namespace current]::inst$_instCounter
            }

            # _inst_from_path: find which instance namespace owns the given widget path
            proc _inst_from_path {path} {
                # Look up which instance namespace owns the given widget path.
                # Use the cached module namespace name `_modns` and fully-qualify
                # the array access to avoid fragile `variable` scoping issues.
                variable _modns

                # Defensive check: if the module-var doesn't exist, fail cleanly.
                if {![info exists _modns] || [string length $_modns] == 0} {
                    dbg "_inst_from_path: internal error: module namespace not set"
                    return {}
                }

                # Fully-qualified array element name, e.g. ::myns::path2ns(.foo)
                set fq "${_modns}::path2ns($path)"

                # Use info exists on the fully-qualified element; if present, return it.
                if {[info exists $fq]} {
                    # Use set with the qualified name to return the value.
                    return [set ${_modns}::path2ns($path)]
                }
                return {}
            }

            ################################################################
            # Public API: create
            ################################################################

            # create path ?-option value ...?
            # Creates a flexframe instance at widget path and defines a command
            # at that path to operate the widget.
            # ARGUMENTS:
            #   path - widget path where the composite frame will be created
            #   options - widget options as specified in the man page
            # RETURN: none; defines the widget command
            proc create {path args} {
                # choose an instance namespace under this module in caller
                set instNs [_makeInstNs]
                
                # TEST
                dbg "[clock format [clock seconds]] _create: path=$path instNs=$instNs"
                
                # create data structures in the instance namespace
                # initialize arrays explicitly so later `namespace eval` or
                # `info exists` checks don't accidentally treat them as scalars
                namespace eval $instNs {
                    variable w          ;# base frame Tk path
                    variable cfg
                    variable children {}
                    array set items {}
                    array set itemsTag {}
                    variable canvas
                    variable vscroll
                    variable needVScroll 0
                    variable needHScroll 0
                }

                # Default configuration
                set defaults {
                    -orient vertical
                    -start nw
                    -autoscroll 1
                    -debug 0
                    -minsize {}
                    -sticky news
                    -minpad 0
                    -spacing 0
                }

                # parse args quickly: allow -option value pairs
                array set given {}
                for {set i 0} {$i < [llength $args]} {incr i 2} {
                    set opt [lindex $args $i]
                    set val [lindex $args [expr {$i+1}]]
                    set given($opt) $val
                }

                # create the Tk base frame; store in w
                ::frame $path
                namespace eval $instNs [list set w $path]

                # store path and defaults inside the instance namespace
                namespace eval $instNs {array set cfg {}}
                
                # record mapping from the widget path to the instance namespace
                set path2ns($path) $instNs
                # TEST
                dbg "[clock format [clock seconds]] _create: registered path2ns($path)=$instNs"
                
                # copy defaults into instance namespace (expand in outer scope)
                foreach {k v} $defaults {
                    namespace eval $instNs [list set cfg($k) $v]
                }
                # apply given options (expand in outer scope then set in instance ns)
                foreach {k v} [array get given] {
                    namespace eval $instNs [list set cfg($k) $v]
                }

                set canvasName ${path}.c
                ::canvas $canvasName -highlightthickness 0 -borderwidth 0 -confine 1
                grid $canvasName -row 0 -column 0 -sticky news
                namespace eval $instNs [list set canvas $canvasName]

                # Create both vertical and horizontal scrollbars. We will show
                # or hide them in _recalc depending on orientation and content.
                set vscrollName ${path}.vs
                ttk::scrollbar $vscrollName -orient vertical -command [list $canvasName yview]
                grid $vscrollName -row 0 -column 1 -sticky ns
                eval [list $canvasName configure -yscrollcommand [list $vscrollName set]]
                namespace eval $instNs [list set vscroll $vscrollName]

                set hscrollName ${path}.hs
                ttk::scrollbar $hscrollName -orient horizontal -command [list $canvasName xview]
                grid $hscrollName -row 1 -column 0 -sticky ew
                eval [list $canvasName configure -xscrollcommand [list $hscrollName set]]
                namespace eval $instNs [list set hscroll $hscrollName]

                # allow frame to expand (grid manager row/columnconfigure)
                grid rowconfigure $path 0 -weight 1
                grid columnconfigure $path 0 -weight 1

                
                # bind configure events to recalc layout
                # need to capture instNs in closure form
                # use the module-scoped cached `_modns` so we always operate on
                # the same module namespace regardless of local scoping.
                variable _modns

                # Ensure the global module mapping is written into the module namespace
                # (fully-qualified) so dispatch-time lookups find it reliably.
                namespace eval $_modns [list set path2ns($path) $instNs]
                dbg "[clock format [clock seconds]] _create: registered (module) path2ns($path)=[namespace eval $_modns [list set path2ns($path)]]"

                # Bind configure events to call the module-level _onConfigure
                # directly with the instance namespace and widget path captured
                # as literal arguments. This avoids creating transient per-widget
                # interp aliases which can be fragile after command renames.
                eval [list bind $path <Configure> [list ${_modns}::_onConfigure $instNs $path]]
                eval [list bind $canvasName <Configure> [list ${_modns}::_onConfigure $instNs $path]]

                # The frame widget creation above created a widget command named
                # exactly as $path. Rename that widget command to ${path}_internal
                # so we can provide a dispatcher at $path which handles subcommands.
                set internalName "${path}_internal"
                
                # If an internal name already exists, move it aside
                if {[llength [info commands $internalName]] > 0} {
                    catch {rename $internalName ${internalName}__old}
                }
                # If the widget command exists, rename it to the internal name.
                if {[llength [info commands $path]] > 0} {
                    if {[catch {rename $path $internalName} err]} {
                        puts "warning: failed to rename $path to $internalName: $err"
                    }
                }

                # Expose the dispatcher at $path via interp alias so calls like
                # "$path add ..." resolve to flexframe::_cmd_dispatch
                if {[catch {interp alias {} $path {} ${_modns}::_cmd_dispatch $path} err2]} {
                    puts "warning: interp alias failed for $path: $err2"
                }

                # configure/cget are available via the command dispatch (e.g. "$path configure ...").
                # We avoid creating additional interp aliases with unusual names.

                # initial layout
                ${_modns}::_recalc $instNs $path
            }

            ################################################################
            # Internal command dispatch and public commands
            ################################################################

            # _cmd_dispatch: main dispatcher for per-instance command
            proc _cmd_dispatch {path cmd args} {
                variable _modns
                # Diagnostic: show module namespace and currently-registered path2ns keys
                if {[info exists _modns] && $_modns ne {}} {
                    dbg "[clock format [clock seconds]] _cmd_dispatch: module=$_modns path2ns keys=[namespace eval $_modns {join [array names path2ns] , }]"
                } else {
                    dbg "[clock format [clock seconds]] _cmd_dispatch: module=(unset)"
                }
                dbg "[clock format [clock seconds]] _cmd_dispatch: path=$path cmd=$cmd args=$args"
                switch -- $cmd {
                    add {return [eval [list _cmd_add $path] $args]}
                    remove {return [eval [list _cmd_remove $path] $args]}
                    configure {return [eval [list _cmd_configure $path] $args]}
                    cget {return [eval [list _cmd_cget $path] $args]}
                    children {return [_cmd_children $path]}
                    clear {return [eval [list _cmd_clear $path] $args]}
                    default {error "unknown subcommand $cmd"}
                }
            }

            # _cmd_configure: set or query options
            proc _cmd_configure {path args} {
                # get instance ns from path->canvas mapping: we stored instance ns
                set instNs [_inst_from_path $path]
                if {$instNs eq {}} {error "internal: instance namespace not found"}
                # no-op here; cfg_get will access instance values when needed
                if {[llength $args] == 0} {
                    # return list describing available options: name dbname dbclass default current
                    set result {}
                    namespace eval $instNs {
                        foreach {k v} [array get cfg] {
                            lappend result $k {} {} $v $v
                        }
                    }
                    return $result
                } elseif {[llength $args] == 1} {
                    set opt [lindex $args 0]
                    namespace eval $instNs {variable cfg}
                    return [cfg_get $instNs $opt]
                } else {
                    # set pairs
                    set i 0
                    while {$i < [llength $args]} {
                        set opt [lindex $args $i]; incr i
                        set val [lindex $args $i]; incr i
                        cfg_set $instNs $opt $val
                    }
                    # after configure, recalc
                    _recalc $instNs $path
                    return ""
                }
            }

            # _cmd_cget: return value for option
            proc _cmd_cget {path opt} {
                set instNs [_inst_from_path $path]
                if {$instNs eq {}} {error "internal: instance namespace not found"}
                namespace eval $instNs {variable cfg}
                    return [cfg_get $instNs $opt]
            }

            # _cmd_children: return children list
            proc _cmd_children {path} {
                set instNs [_inst_from_path $path]
                if {$instNs eq {}} {error "internal: instance namespace not found"}
                return [inst_get $instNs children]
            }

            # _cmd_clear: remove one or all children of the instance
            proc _cmd_clear {path args} {
                set instNs [_inst_from_path $path]
                namespace eval $instNs {variable children}
                # remove canvas items
                # delete canvas items recorded in the instance 'items' array
                namespace eval $instNs {
                    variable items; variable canvas
                    foreach child $children {
                        if {[info exists items($child)]} {
                            set id $items($child)
                            if {$id ne {}} {$canvas delete $id}
                            unset items($child)
                        }
                    }
                    set children {}
                }
                _recalc $instNs $path
            }

            # _cmd_add: add a child widget into the flexframe at optional index
            proc _cmd_add {path childPath args} {
                # TEST
                variable _modns
                variable lastAdded
                variable itemsMap
                dbg "Entering _cmd_add: path=$path child=$childPath args=$args"
                if {[info exists _modns] && $_modns ne {}} {
                    dbg "[clock format [clock seconds]] _cmd_add: module=$_modns path2ns keys=[namespace eval $_modns {join [array names path2ns] , }]"
                }
                
                set index {}
                if {[llength $args] > 0} {set index [lindex $args 0]}
                
                set instNs [_inst_from_path $path]
                if {$instNs eq {}} {error "internal: instance namespace not found"}
                
                namespace eval $instNs {
                    variable children; variable items; variable canvas
                }
                # debug: show entry and current module storage snapshot
                idbg $instNs "[clock format [clock seconds]] _cmd_add: ENTER path=$path child=$childPath instNs=$instNs"
                idbg $instNs "[clock format [clock seconds]] _cmd_add: pre-store lastAdded=[info exists lastAdded] value=[set lastAdded]"
                idbg $instNs "[clock format [clock seconds]] _cmd_add: pre-store itemsMap keys=[join [array names itemsMap] , ]"
                # ensure child exists
                if {![winfo exists $childPath]} {error "child $childPath doesn't exist"}

                # Require that children be created as descendants of the flexframe
                # instance (e.g. ${path}.child). This prevents reparenting and
                # geometry races caused by adding widgets managed elsewhere.
                if {[string match "${path}.*" $childPath] == 0} {
                    error "child '$childPath' must be created as a descendant of '$path' (e.g. '${path}.name')"
                }

                # insert into list
                if {$index eq {}} {
                    namespace eval $instNs [list lappend children $childPath]
                } else {
                    if {$index eq "end"} {
                        namespace eval $instNs [list lappend children $childPath]
                    } else {
                        set nindex [expr {$index < 0 ? 0 : $index}]
                        namespace eval $instNs [list set children [linsert $children $nindex $childPath]]
                    }
                }

                # We no longer create the canvas window here; defer to _recalc which
                # deterministically creates or finds canvas windows by tag.
                idbg $instNs "[clock format [clock seconds]] _cmd_add: appended child $childPath to $path (scheduling recalc)"
                ${_modns}::_schedule_recalc $instNs $path
            }

            # _cmd_remove: remove child
            proc _cmd_remove {path childPath} {
                variable _modns
                set instNs [${_modns}::_inst_from_path $path]
                if {$instNs eq {}} {error "internal: instance namespace not found"}

                # fetch current children list
                set children [inst_get $instNs children]
                set new {}
                foreach c $children {
                    if {$c ne $childPath} {
                        lappend new $c
                    } else {
                        # delete the canvas item if it exists (instance-local storage)
                        set canvasWidget [inst_get $instNs canvas]
                        if {[namespace eval $instNs [list info exists items($childPath)]]} {
                            set id [namespace eval $instNs [list set items($childPath)]]
                            if {$id ne {}} {eval [list $canvasWidget delete $id]}
                            namespace eval $instNs [list unset items($childPath)]
                        }
                    }
                }
                # store updated children list
                inst_set $instNs children $new
                _recalc $instNs $path
            }

            

            ################################################################
            # Layout calculation and reflow
            ################################################################

            # _schedule_recalc: debounce layout recalculation for an instance
            proc _schedule_recalc {instNs path} {
                variable _modns
                # cancel any pending idle callback for this instance
                if {[namespace eval $instNs {info exists _afterRecalcId}]} {
                    set old [namespace eval $instNs {set _afterRecalcId}]
                    if {$old ne ""} {
                        catch {after cancel $old}
                    }
                }
                # schedule a single idle-time recalc using fully-qualified proc
                set id [after idle [list ${_modns}::_recalc $instNs $path]]
                namespace eval $instNs [list set _afterRecalcId $id]
            }

            # _onConfigure: called when outer frame or canvas is resized.
            proc _onConfigure {instNs path args} {
                # schedule (debounced) recalc to avoid duplicate rapid calls
                _schedule_recalc $instNs $path
            }

            # _recalc: compute parcel sizes, number of columns/rows and place children
            proc _recalc {instNs path} {
                namespace eval $instNs {
                    variable cfg; variable children; variable items; variable canvas; variable vscroll
                }

                # Let pending geometry settle before we measure and create windows.
                update idletasks

                # get current canvas viewport size (fetch into local vars)
                set wh [namespace eval $instNs {list [winfo width $canvas] [winfo height $canvas]}]
                set w [lindex $wh 0]
                set h [lindex $wh 1]

                # If not yet realized (0), try to use requested sizes
                if {$w <= 1 || $h <= 1} {
                    set wh [namespace eval $instNs {list [winfo reqwidth $canvas] [winfo reqheight $canvas]}]
                    set w [lindex $wh 0]
                    set h [lindex $wh 1]
                }

                # get children count and max child requested sizes from instance namespace
                set stats [namespace eval $instNs {
                    variable children
                    set n [llength $children]
                    set maxw 0
                    set maxh 0
                    foreach c $children {
                        if {[winfo exists $c]} {
                            set rw [winfo reqwidth $c]
                            set rh [winfo reqheight $c]
                            if {$rw > $maxw} {set maxw $rw}
                            if {$rh > $maxh} {set maxh $rh}
                        }
                    }
                    list $n $maxw $maxh
                }]
                set n [lindex $stats 0]
                set maxw [lindex $stats 1]
                set maxh [lindex $stats 2]

                if {$n == 0} {
                    # nothing to do
                    return
                }

                # parcel size is max of maxw and maxh (square parcel)
                # TODO: parcels can be rectangular
                set parcel [expr {($maxw > $maxh) ? $maxw : $maxh}]
                if {$parcel < 1} {set parcel 1}

                # read configuration values from instance namespace
                # Use the first lowercased character as the orientation key.
                # Validation of allowed values should be done when setting the option.
                set orientRaw [string tolower [string trim [cfg_get $instNs -orient]]]
                if {$orientRaw eq ""} {
                    set orient "v"
                } else {
                    set orient [string index $orientRaw 0]
                }
                set spacing [_px $path [cfg_get $instNs -spacing]]
                set minpad [_px $path [cfg_get $instNs -minpad]]
                set minsizeSpec [cfg_get $instNs -minsize]
                set autoscroll [cfg_get $instNs -autoscroll]

                # initialize scroll flags so diagnostics can safely reference them
                set needV 0
                set needH 0

                # compute how many columns/rows depending on orientation
                if {$orient eq "v"} {
                    # width is stretchy dimension; number of columns = floor((w - 2*minpad + spacing)/(parcel+spacing))
                    set availW $w
                    set cols [expr {int((($availW - 2*$minpad) + $spacing)/($parcel + $spacing))}]
                    if {$cols < 1} {set cols 1}
                    set rows [expr {int((($n + $cols -1)/$cols))}]
                    # compute content height
                    set contentH [expr {$rows*$parcel + ($rows-1)*$spacing + 2*$minpad}]
                    # decide if scrollbar required
                    if {$autoscroll && $contentH > $h} {
                        # ensure scrollbar visible
                        set needV 1
                    } else {set needV 0}
                    # if scrollbar will appear it reduces availW; recompute with scrollbar width
                    if {$needV} {
                        set vscrollWidget [inst_get $instNs vscroll]
                        set sW [winfo reqwidth $vscrollWidget]
                        set availW2 [expr {$w - $sW}]
                        set cols [expr {int((($availW2 - 2*$minpad) + $spacing)/($parcel + $spacing))}]
                        if {$cols < 1} {set cols 1}
                        set rows [expr {int((($n + $cols -1)/$cols))}]
                        set contentH [expr {$rows*$parcel + ($rows-1)*$spacing + 2*$minpad}]
                    }
                    # compute columns again
                } else {
                    # horizontal growth: roles swapped
                    set availH $h
                    set rows [expr {int((($availH - 2*$minpad) + $spacing)/($parcel + $spacing))}]
                    if {$rows < 1} {set rows 1}
                    set cols [expr {int((($n + $rows -1)/$rows))}]
                    set contentW [expr {$cols*$parcel + ($cols-1)*$spacing + 2*$minpad}]
                    if {$autoscroll && $contentW > $w} {set needH 1} else {set needH 0}
                    if {$needH} {
                        set hscrollWidget [inst_get $instNs hscroll]
                        set sH [winfo reqheight $hscrollWidget]
                        set availH2 [expr {$h - $sH}]
                        set rows [expr {int((($availH2 - 2*$minpad) + $spacing)/($parcel + $spacing))}]
                        if {$rows < 1} {set rows 1}
                        set cols [expr {int((($n + $rows -1)/$rows))}]
                        set contentW [expr {$cols*$parcel + ($cols-1)*$spacing + 2*$minpad}]
                    }
                }

                # TEST : report layout decisions and items
                idbg $instNs "[clock format [clock seconds]] _recalc $path -- w=$w h=$h n=$n maxw=$maxw maxh=$maxh parcel=$parcel spacing=$spacing minpad=$minpad cols=$cols rows=$rows needV=$needV needH=$needH"
                # TEST : print module-level itemsMap entries for this instance
                variable itemsMap
                variable lastAdded
                idbg $instNs "[clock format [clock seconds]] itemsMap keys: [join [array names itemsMap] , ]"

                # Place children in order into the grid determined by rows/cols and anchor
                # interpret -start anchor
                set start [cfg_get $instNs -start]
                # default anchor options
                set xdir 1; set ydir 1
                set startx 0; set starty 0
                switch -- $start {
                    nw {set xdir 1; set ydir 1}
                    ne {set xdir -1; set ydir 1}
                    sw {set xdir 1; set ydir -1}
                    se {set xdir -1; set ydir -1}
                }

                # For simplicity we compute positions so that parcels are placed as squares
                # Compute for orient v: fill horizontally first (cols) then wrap to next row
                # Fetch the children list and items mapping via the helper to avoid
                # namespace scoping oddities.
                set children [inst_get $instNs children]
                # Diagnostic: show raw children value and length, and canvas widget
                idbg $instNs "[clock format [clock seconds]] _recalc: children='$children' llength=[llength $children]"
                set canvasWidget [inst_get $instNs canvas]
                idbg $instNs "[clock format [clock seconds]] _recalc: canvasWidget=$canvasWidget"
                idbg $instNs "[clock format [clock seconds]] _recalc: instance children (ns): [join [namespace eval $instNs {array get children}] , ]"
                set i 0
                foreach child $children {
                    set idx $i
                    if {$orient eq "v"} {
                        set col [expr {$idx % $cols}]
                        set row [expr {int($idx / $cols)}]
                    } else {
                        set row [expr {$idx % $rows}]
                        set col [expr {int($idx / $rows)}]
                    }
                    # compute top-left corner inside canvas
                    set x [expr {$minpad + $col*($parcel + $spacing)}]
                    set y [expr {$minpad + $row*($parcel + $spacing)}]
                    # adjust for start anchors xdir/ydir; if start indicates right-to-left, reflect
                    if {$xdir < 0} {
                        set x [expr {$w - $minpad - ($col+1)*$parcel - $col*$spacing}]
                    }
                    if {$ydir < 0} {
                        set y [expr {$h - $minpad - ($row+1)*$parcel - $row*$spacing}]
                    }

                    # compute anchor for canvas create_window according to -start
                    set anchor [cfg_get $instNs -start]

                    idbg $instNs "[clock format [clock seconds]] _recalc: checking child=$child winfo_exists=[winfo exists $child] canvasWidget=$canvasWidget"

                    if {[namespace eval $instNs [list info exists items($child)]]} {
                        set itemId [namespace eval $instNs [list set items($child)]]
                        if {$itemId ne ""} {
                            eval [list $canvasWidget coords $itemId $x $y]
                            eval [list $canvasWidget itemconfigure $itemId -anchor $anchor]
                        }
                    } elseif {[namespace eval $instNs [list info exists itemsTag($child)]]} {
                        set tagFound [namespace eval $instNs [list set itemsTag($child)]]
                        set found [eval [list $canvasWidget find withtag $tagFound]]
                        if {[llength $found] > 0} {
                            set id [lindex $found 0]
                            namespace eval $instNs [list set items($child) $id]
                            eval [list $canvasWidget coords $id $x $y]
                            eval [list $canvasWidget itemconfigure $id -anchor $anchor]
                        } else {
                            set safePath [string map {. _} $path]
                            set safeChild [string map {. / : _} $child]
                            set tagName "flexframe_${safePath}_${safeChild}"
                            # ensure geometry settled for the child before creating window
                            update idletasks
                            # create the canvas window and capture the returned id
                            set newId [eval [list $canvasWidget create window $x $y -window $child -anchor $anchor -tags $tagName]]
                            idbg $instNs "[clock format [clock seconds]] _recalc: create returned newId=$newId for child=$child"
                            if {$newId eq {}} {
                                idbg $instNs "[clock format [clock seconds]] _recalc: ERROR creating window for $child (empty id)"
                            } else {
                                namespace eval $instNs [list set items($child) $newId]
                                namespace eval $instNs [list set itemsTag($child) $tagName]
                                set key [list $path $child]
                                set itemsMap($key) $newId
                                set lastAdded $key
                                idbg $instNs "[clock format [clock seconds]] _recalc: created window id $newId for $child (stored key=$key tag=$tagName)"
                            }
                        }
                    } else {
                        set safePath [string map {. _} $path]
                        set safeChild [string map {. / : _} $child]
                        set tagName "flexframe_${safePath}_${safeChild}"
                        update idletasks
                        set newId [eval [list $canvasWidget create window $x $y -window $child -anchor $anchor -tags $tagName]]
                        idbg $instNs "[clock format [clock seconds]] _recalc: create returned newId=$newId for child=$child"
                        if {$newId eq {}} {
                            idbg $instNs "[clock format [clock seconds]] _recalc: ERROR creating window for $child (empty id)"
                        } else {
                            namespace eval $instNs [list set items($child) $newId]
                            namespace eval $instNs [list set itemsTag($child) $tagName]
                            set key [list $path $child]
                            set itemsMap($key) $newId
                            set lastAdded $key
                            idbg $instNs "[clock format [clock seconds]] _recalc: created window id $newId for $child (stored key=$key tag=$tagName)"
                        }
                    }
                    incr i
                }

                # update scrollregion and show/remove scrollbar as needed
                set contentW [expr {$cols*$parcel + ($cols-1)*$spacing + 2*$minpad}]
                set contentH [expr {$rows*$parcel + ($rows-1)*$spacing + 2*$minpad}]
                set canvasWidget [inst_get $instNs canvas]
                eval [list $canvasWidget configure -scrollregion [list 0 0 $contentW $contentH]]
                set vscrollWidget [inst_get $instNs vscroll]
                set hscrollWidget [inst_get $instNs hscroll]
                if {$needV} {
                    eval [list grid $vscrollWidget -row 0 -column 1 -sticky ns]
                } else {
                    eval [list grid remove $vscrollWidget]
                }
                if {$needH} {
                    eval [list grid $hscrollWidget -row 1 -column 0 -sticky ew]
                } else {
                    eval [list grid remove $hscrollWidget]
                }

                # Final diagnostics: list canvas items and per-instance items array
                idbg $instNs "[clock format [clock seconds]] _recalc: canvas find all -> [eval [list $canvasWidget find all]]"
                idbg $instNs "[clock format [clock seconds]] _recalc: instance items (ns) -> [namespace eval $instNs {join [array names items] , }]"
            }

        } ;# end namespace flexframe

        # Diagnostic: dump internal module state for debugging
        proc dump_state {} {
            # Only produce dump output when module debug is enabled.
            variable debug
            if {![info exists debug] || !$debug} {return ""}
            variable path2ns
            puts "--- flexframe::dump_state ---"
            puts "path2ns keys: [join [array names path2ns] , ]"
            foreach p [array names path2ns] {
                set inst [set path2ns($p)]
                puts "instance $p -> $inst"
                catch {namespace eval $inst {variable items; variable itemsTag; variable canvas; puts "  items: [join [array names items] , ] ; itemsTag: [join [array names itemsTag] , ] ; canvas=$canvas"}} err
                # show canvas items by tag if present
                catch {
                    namespace eval $inst {
                        foreach child [array names itemsTag] {
                            set tag $itemsTag($child)
                            set found [eval [list $canvas find withtag $tag]]
                            puts "  child $child tag=$tag found=[join $found , ]"
                        }
                    }
                } err2
            }
            puts "--- end dump ---"
            return ""
        }

        # Provide a convenient creation command in the namespace where this
        # file was sourced. The requested usage is:
        #     flexframe _tkpath_ ?-option value ...?
        # We only create this helper if it does not already exist in the
        # current namespace so we avoid clobbering user commands.
        if {[llength [info procs flexframe]] == 0} {
            proc flexframe {path args} {
                # delegate creation to the module; expand args properly
                return [eval [list flexframe::create $path] $args]
            }
        }
        # Note: compatibility shims for a root-based ::flexframe namespace were
        # intentionally removed. This module creates a `flexframe` namespace
        # under the namespace that sources this file (via
        # `namespace eval [namespace current] { namespace eval flexframe { ... } }`).
        # Callers should reference the module relative to their namespace or use
        # the provided `flexframe` helper proc in the sourcing namespace.
    }
}

# End of flexframe.tcl
