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
    if {![info exists ::flexframe_loaded]} {
        variable ::flexframe_loaded 1

        # Base namespace for this module inside the current namespace.
        namespace eval ::flexframe {

            # Instance counter for unique instance namespaces
            variable _instCounter 0
            # mapping from widget path -> instance namespace
            variable path2ns
            # global mapping for canvas item ids: key is "instNs|childPath" -> id
            variable itemsMap
            # lastAdded for diagnostics (store the last key added)
            variable lastAdded {}
            # Ensure storage is initialized (avoid relying on lazy creation)
            array set itemsMap {}
            set lastAdded ""

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
                namespace eval $instNs [list set cfg($key) $val]
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
                set instNs [::flexframe::_makeInstNs]
                puts "[clock format [clock seconds]] _create: path=$path instNs=$instNs"
                # create data structures in the instance namespace
                namespace eval $instNs {
                    variable w
                    variable cfg
                    variable children
                    variable items   ;# mapping child -> canvas item id
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

                # create the outer frame
                eval ::frame $path

                # store path and defaults inside the instance namespace
                namespace eval $instNs {array set cfg {}}
                # set the widget path into the instance namespace (expand $path here)
                namespace eval $instNs [list set w $path]
                # record mapping from the widget path to the instance namespace
                set ::flexframe::path2ns($path) $instNs
                puts "[clock format [clock seconds]] _create: registered path2ns($path)=$instNs"
                # copy defaults into instance namespace (expand in outer scope)
                foreach {k v} $defaults {
                    namespace eval $instNs [list set cfg($k) $v]
                }
                # apply given options (expand in outer scope then set in instance ns)
                foreach {k v} [array get given] {
                    namespace eval $instNs [list set cfg($k) $v]
                }

                # inside frame create a canvas (viewport) and scrollbar(s)
                set canvasName ${path}.c
                set vscrollName ${path}.vs
                ::canvas $canvasName -highlightthickness 0 -borderwidth 0
                ::scrollbar $vscrollName -orient vertical -command [list $canvasName yview]

                # put canvas and scrollbar into the outer frame using grid
                eval [list grid $canvasName -row 0 -column 0 -sticky news]
                eval [list grid $vscrollName -row 0 -column 1 -sticky ns]
                # allow frame to expand (grid manager row/columnconfigure)
                eval [list grid rowconfigure $path 0 -weight 1]
                eval [list grid columnconfigure $path 0 -weight 1]

                # set canvas scroll commands (pass list to avoid word-splitting)
                eval [list $canvasName configure -yscrollcommand [list $vscrollName set]]

                # initialize internal variables (set names/vars with expanded values)
                namespace eval $instNs [list set canvas $canvasName]
                namespace eval $instNs [list set vscroll $vscrollName]
                namespace eval $instNs {set children {}}


                # bind configure events to recalc layout
                # need to capture instNs in closure form
                interp alias {} ${path}::_ontkcfg {} ::flexframe::_onConfigure $instNs $path
                eval [list bind $path <Configure> [list ::flexframe::_onConfigure $instNs $path]]
                eval [list bind $canvasName <Configure> [list ::flexframe::_onConfigure $instNs $path]]

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
                # "$path add ..." resolve to ::flexframe::_cmd_dispatch
                if {[catch {interp alias {} $path {} ::flexframe::_cmd_dispatch $path} err2]} {
                    puts "warning: interp alias failed for $path: $err2"
                }

                # configure/cget are available via the command dispatch (e.g. "$path configure ...").
                # We avoid creating additional interp aliases with unusual names.

                # initial layout
                ::flexframe::_recalc $instNs $path
            }

            ################################################################
            # Internal command dispatch and public commands
            ################################################################

            # _cmd_dispatch: main dispatcher for per-instance command
            proc _cmd_dispatch {path cmd args} {
                puts "[clock format [clock seconds]] _cmd_dispatch: path=$path cmd=$cmd args=$args"
                switch -- $cmd {
                    add {return [eval [list ::flexframe::_cmd_add $path] $args]}
                    remove {return [eval [list ::flexframe::_cmd_remove $path] $args]}
                    configure {return [eval [list ::flexframe::_cmd_configure $path] $args]}
                    cget {return [eval [list ::flexframe::_cmd_cget $path] $args]}
                    children {return [::flexframe::_cmd_children $path]}
                    clear {return [eval [list ::flexframe::_cmd_clear $path] $args]}
                    default {error "unknown subcommand $cmd"}
                }
            }

            # _cmd_configure: set or query options
            proc _cmd_configure {path args} {
                # get instance ns from path->canvas mapping: we stored instance ns
                set instNs [::flexframe::_inst_from_path $path]
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
                    return [::flexframe::cfg_get $instNs $opt]
                } else {
                    # set pairs
                    set i 0
                    while {$i < [llength $args]} {
                        set opt [lindex $args $i]; incr i
                        set val [lindex $args $i]; incr i
                        ::flexframe::cfg_set $instNs $opt $val
                    }
                    # after configure, recalc
                    ::flexframe::_recalc $instNs $path
                    return ""
                }
            }

            # _cmd_cget: return value for option
            proc _cmd_cget {path opt} {
                set instNs [::flexframe::_inst_from_path $path]
                if {$instNs eq {}} {error "internal: instance namespace not found"}
                namespace eval $instNs {variable cfg}
                    return [::flexframe::cfg_get $instNs $opt]
            }

            # _cmd_children: return children list
            proc _cmd_children {path} {
                set instNs [::flexframe::_inst_from_path $path]
                return [::flexframe::inst_get $instNs children]
            }

            # _cmd_clear: remove one or all children of the instance
            proc _cmd_clear {path args} {
                set instNs [::flexframe::_inst_from_path $path]
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
                ::flexframe::_recalc $instNs $path
            }

            # _cmd_add: add a child widget into the flexframe at optional index
            proc _cmd_add {path childPath args} {
                set index {}
                if {[llength $args] > 0} {set index [lindex $args 0]}
                set instNs [::flexframe::_inst_from_path $path]
                if {$instNs eq {}} {error "internal: instance namespace not found"}
                namespace eval $instNs {
                    variable children; variable items; variable canvas
                }
                # debug: show entry and current module storage snapshot
                puts "[clock format [clock seconds]] _cmd_add: ENTER path=$path child=$childPath instNs=$instNs"
                puts "[clock format [clock seconds]] _cmd_add: pre-store ::flexframe::lastAdded=[info exists ::flexframe::lastAdded] value=[set ::flexframe::lastAdded]"
                puts "[clock format [clock seconds]] _cmd_add: pre-store itemsMap keys=[join [array names ::flexframe::itemsMap] , ]"
                # ensure child exists
                if {![winfo exists $childPath]} {error "child $childPath doesn't exist"}

                # if child currently managed by geometry, forget it
                catch {pack forget $childPath}
                catch {grid forget $childPath}
                catch {place forget $childPath}

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
                puts "[clock format [clock seconds]] _cmd_add: appended child $childPath to $path (recalc will create window)"
                ::flexframe::_recalc $instNs $path
            }

            # _cmd_remove: remove child
            proc _cmd_remove {path childPath} {
                set instNs [::flexframe::_inst_from_path $path]
                if {$instNs eq {}} {error "internal: instance namespace not found"}

                # fetch current children list
                set children [::flexframe::inst_get $instNs children]
                set new {}
                foreach c $children {
                    if {$c ne $childPath} {
                        lappend new $c
                    } else {
                        # delete the canvas item if it exists (instance-local storage)
                        namespace eval $instNs {
                            variable items
                            if {[info exists items($childPath)]} {
                                set id $items($childPath)
                                set canvasWidget $canvas
                                if {$id ne {}} {eval [list $canvasWidget delete $id]}
                                unset items($childPath)
                            }
                        }
                    }
                }
                # store updated children list
                ::flexframe::inst_set $instNs children $new
                ::flexframe::_recalc $instNs $path
            }

            # _inst_from_path: find which instance namespace owns the given widget path
            proc _inst_from_path {path} {
                # Prefer the explicit mapping created at instance creation time.
                variable path2ns
                if {[info exists path2ns($path)]} {return $path2ns($path)}
                return {}
            }

            ################################################################
            # Layout calculation and reflow
            ################################################################

            # _onConfigure: called when outer frame or canvas is resized.
            proc _onConfigure {instNs path args} {
                # simply trigger a recalc
                ::flexframe::_recalc $instNs $path
            }

            # _recalc: compute parcel sizes, number of columns/rows and place children
            proc _recalc {instNs path} {
                namespace eval $instNs {
                    variable cfg; variable children; variable items; variable canvas; variable vscroll
                }

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
                set parcel [expr {($maxw > $maxh) ? $maxw : $maxh}]
                if {$parcel < 1} {set parcel 1}

                # read configuration values from instance namespace
                set orientRaw [::flexframe::cfg_get $instNs -orient]
                set orient [lindex [split $orientRaw " "] 0]
                set orient [string tolower $orient]
                if {$orient == "v" || $orient == "vertical"} {set orient v} else {set orient h}
                set spacing [::flexframe::_px $path [::flexframe::cfg_get $instNs -spacing]]
                set minpad [::flexframe::_px $path [::flexframe::cfg_get $instNs -minpad]]
                set minsizeSpec [::flexframe::cfg_get $instNs -minsize]
                set autoscroll [::flexframe::cfg_get $instNs -autoscroll]

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
                        set vscrollWidget [::flexframe::inst_get $instNs vscroll]
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
                        set vscrollWidget [::flexframe::inst_get $instNs vscroll]
                        set sH [winfo reqheight $vscrollWidget]
                        set availH2 [expr {$h - $sH}]
                        set rows [expr {int((($availH2 - 2*$minpad) + $spacing)/($parcel + $spacing))}]
                        if {$rows < 1} {set rows 1}
                        set cols [expr {int((($n + $rows -1)/$rows))}]
                        set contentW [expr {$cols*$parcel + ($cols-1)*$spacing + 2*$minpad}]
                    }
                }

                # debug: report layout decisions and items
                puts "[clock format [clock seconds]] flexframe::_recalc $path -- w=$w h=$h n=$n maxw=$maxw maxh=$maxh parcel=$parcel spacing=$spacing minpad=$minpad cols=$cols rows=$rows needV=$needV needH=$needH"
                # print module-level itemsMap entries for this instance
                variable itemsMap
                puts "[clock format [clock seconds]] itemsMap keys: [join [array names itemsMap] , ]"

                # Place children in order into the grid determined by rows/cols and anchor
                # interpret -start anchor
                set start [::flexframe::cfg_get $instNs -start]
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
                # Fetch the children list and items mapping locally; other structures live in instance ns
                set children [namespace eval $instNs {return $children}]
                # build a local dict of child -> itemId using the instance 'items' array
                # if an item id is not present, try to find the canvas item by its stored tag
                set itemsDict {}
                namespace eval $instNs {
                    variable items; variable itemsTag; variable canvas
                    foreach child $children {
                        if {[info exists items($child)]} {
                            dict set ::itemsDict $child $items($child)
                        } elseif {[info exists itemsTag($child)]} {
                            set tag $itemsTag($child)
                            # find the canvas item with that tag
                            set found [eval [list $canvas find withtag $tag]]
                            if {[llength $found] > 0} {
                                dict set ::itemsDict $child [lindex $found 0]
                                # store back into items array for future
                                set items($child) [lindex $found 0]
                            }
                        }
                    }
                }
                set canvasWidget [::flexframe::inst_get $instNs canvas]
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
                        if {$orient eq "v"} {
                            # available width to compute right aligned positions
                            set totalW [expr {$cols*$parcel + ($cols-1)*$spacing + 2*$minpad}]
                            set x [expr {$w - $minpad - ($col+1)*$parcel - $col*$spacing}]
                        } else {
                            set totalW [expr {$cols*$parcel + ($cols-1)*$spacing + 2*$minpad}]
                            set x [expr {$w - $minpad - ($col+1)*$parcel - $col*$spacing}]
                        }
                    }
                    if {$ydir < 0} {
                        if {$orient eq v} {
                            set totalH [expr {$rows*$parcel + ($rows-1)*$spacing + 2*$minpad}]
                            set y [expr {$h - $minpad - ($row+1)*$parcel - $row*$spacing}]
                        } else {
                            set totalH [expr {$rows*$parcel + ($rows-1)*$spacing + 2*$minpad}]
                            set y [expr {$h - $minpad - ($row+1)*$parcel - $row*$spacing}]
                        }
                    }

                    # compute anchor for canvas create_window according to -start
                    set anchor [::flexframe::cfg_get $instNs -start]

                    # place window: lookup the canvas item id from the local items dict
                    if {[dict exists $itemsDict $child]} {
                        set itemId [dict get $itemsDict $child]
                        if {$itemId ne {}} {
                            eval [list $canvasWidget coords $itemId $x $y]
                            eval [list $canvasWidget itemconfigure $itemId -anchor $anchor]
                        }
                    } else {
                        # If no canvas window exists for this child yet, create one now
                        set newId [eval [list $canvasWidget create window $x $y -window $child -anchor $anchor]]
                        # store in module-level itemsMap for future reference using the canonical key
                        set key [list $path $child]
                        set ::flexframe::itemsMap($key) $newId
                        set ::flexframe::lastAdded $key
                        dict set itemsDict $child $newId
                        puts "[clock format [clock seconds]] _recalc: created window id $newId for $child (stored key=$key)"
                    }
                    incr i
                }

                # update scrollregion and show/remove scrollbar as needed
                set contentW [expr {$cols*$parcel + ($cols-1)*$spacing + 2*$minpad}]
                set contentH [expr {$rows*$parcel + ($rows-1)*$spacing + 2*$minpad}]
                set canvasWidget [::flexframe::inst_get $instNs canvas]
                eval [list $canvasWidget configure -scrollregion [list 0 0 $contentW $contentH]]
                set vscrollWidget [::flexframe::inst_get $instNs vscroll]
                if {$needV} {
                    eval [list grid $vscrollWidget -row 0 -column 1 -sticky ns]
                } else {
                    eval [list grid remove $vscrollWidget]
                }
            }

        } ;# end namespace ::flexframe

        # Diagnostic: dump internal module state for debugging
        proc ::flexframe::dump_state {} {
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
        }

        # Provide a convenient creation command in the namespace where this
        # file was sourced. The requested usage is:
        #     flexframe _tkpath_ ?-option value ...?
        # We only create this helper if it does not already exist in the
        # current namespace so we avoid clobbering user commands.
        if {[llength [info procs flexframe]] == 0} {
            proc flexframe {path args} {
                # delegate creation to the module; expand args properly
                return [eval [list ::flexframe::create $path] $args]
            }
        }
    }
}

# End of flexframe.tcl
