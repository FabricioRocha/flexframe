# t-flexframe.tcl
# Test script for the flexframe megawidget. Creates a resizable window with
# two flexframes (vertical and horizontal), each containing 15 numbered
# buttons. Adds control buttons to exercise the widget subcommands.

package require Tk

# Source the megawidget (adjust path if necessary)
set script_dir [file dirname [info script]]
if {$script_dir eq {}} {set script_dir .}
set flexfile [file join $script_dir flexframe.tcl]
if {[file exists $flexfile]} {
    source $flexfile
} else {
    puts stderr "Could not find flexframe.tcl in $script_dir"
    exit 1
}

# Create main window layout
wm title . "flexframe test"

# Ensure the application exits cleanly when the window is closed
wm protocol . WM_DELETE_WINDOW {destroy .; exit}

grid columnconfigure . 0 -weight 1
grid columnconfigure . 1 -weight 1
grid rowconfigure . 0 -weight 1

# Vertical flexframe on left
frame .left -relief groove -borderwidth 2
grid .left -row 0 -column 0 -sticky news
grid rowconfigure .left 0 -weight 1
grid columnconfigure .left 0 -weight 1

flexframe .left.vf -orient vertical -spacing 2 -minpad 5 -start nw -autoscroll 1
grid .left.vf -in .left -row 0 -column 0 -sticky news

# Horizontal flexframe on right
frame .right -relief groove -borderwidth 2
grid .right -row 0 -column 1 -sticky news
grid rowconfigure .right 0 -weight 1
grid columnconfigure .right 0 -weight 1

flexframe .right.hf -orient horizontal -spacing 2 -minpad 5 -start nw -autoscroll 1
grid .right.hf -in .right -row 0 -column 0 -sticky news

# Create 15 square-ish buttons for each flexframe
for {set i 1} {$i <= 15} {incr i} {
    set btnV .vb$i
    button $btnV -text $i -width 4 -height 2
    if {[catch { ::flexframe::_cmd_add .left.vf $btnV } err]} {
        puts "direct add: ::flexframe::_cmd_add .left.vf $btnV -> ERROR: $err"
    } else {
        puts "direct add: ::flexframe::_cmd_add .left.vf $btnV -> OK"
    }
    # Print both global and namespace-internal diagnostics for storage (safe, caught)
    if {[info exists ::flexframe::lastAdded]} {
        puts "lastAdded (global): $::flexframe::lastAdded"
    } else {
        puts "lastAdded (global): (none)"
    }
    if {[catch {namespace eval ::flexframe {set lastAdded}} nsVal]} {
        puts "lastAdded (ns): (none)"
    } else {
        puts "lastAdded (ns): $nsVal"
    }
    if {[info exists ::flexframe::itemsMap]} {
        puts "ItemsMap after left add (global): [join [array names ::flexframe::itemsMap] , ]"
    } else {
        puts "ItemsMap after left add (global): (none)"
    }
    if {[catch {namespace eval ::flexframe {join [array names itemsMap] ,}} nsKeys]} {
        puts "ItemsMap after left add (ns): (none)"
    } else {
        puts "ItemsMap after left add (ns): $nsKeys"
    }
    # show instance-local items for the left instance if available
    if {[catch {namespace eval ::flexframe {set path2ns(.left.vf)}} instNs]} {
        puts "Left instance items: (no instance)"
    } else {
        if {[catch {namespace eval $instNs {join [array names items] ,}} instItems]} {
            puts "Left instance items: (none)"
        } else {
            puts "Left instance items: $instItems"
        }
    }

    set btnH .hb$i
    button $btnH -text $i -width 4 -height 2
    if {[catch { ::flexframe::_cmd_add .right.hf $btnH } err]} {
        puts "direct add: ::flexframe::_cmd_add .right.hf $btnH -> ERROR: $err"
    } else {
        puts "direct add: ::flexframe::_cmd_add .right.hf $btnH -> OK"
    }
    if {[info exists ::flexframe::lastAdded]} {
        puts "lastAdded: $::flexframe::lastAdded"
    } else {
        puts "lastAdded: (none)"
    }
    puts "ItemsMap after right add: [join [array names ::flexframe::itemsMap] , ]"
}

# Diagnostics: show children and items mapping after creation
puts "Left children: [.left.vf children]"
puts "Right children: [.right.hf children]"
puts "ItemsMap keys: [join [array names ::flexframe::itemsMap] , ]"
# Call module dump for a definitive snapshot
if {[catch {::flexframe::dump_state} dsErr]} {puts "dump_state error: $dsErr"}

# Controls for left (vertical) flexframe
frame .controlsL
grid .controlsL -row 1 -column 0 -sticky we -padx 4 -pady 4
button .controlsL.list -text "List children" -command {
    puts "Left children: [.left.vf children]"
}
button .controlsL.remlast -text "Remove last" -command {
    set ch [.left.vf children]
    if {[llength $ch] > 0} {.left.vf remove [lindex $ch end]}
}
button .controlsL.remfirst -text "Remove first" -command {
    set ch [.left.vf children]
    if {[llength $ch] > 0} {.left.vf remove [lindex $ch 0]}
}
button .controlsL.clear -text "Clear" -command {.left.vf clear}

pack .controlsL.list .controlsL.remlast .controlsL.remfirst .controlsL.clear -in .controlsL -side left -padx 2

# Controls for right (horizontal) flexframe
frame .controlsR
grid .controlsR -row 1 -column 1 -sticky we -padx 4 -pady 4
button .controlsR.list -text "List children" -command {
    puts "Right children: [.right.hf children]"
}
button .controlsR.remlast -text "Remove last" -command {
    set ch [.right.hf children]
    if {[llength $ch] > 0} {.right.hf remove [lindex $ch end]}
}
button .controlsR.remfirst -text "Remove first" -command {
    set ch [.right.hf children]
    if {[llength $ch] > 0} {.right.hf remove [lindex $ch 0]}
}
button .controlsR.clear -text "Clear" -command {.right.hf clear}

pack .controlsR.list .controlsR.remlast .controlsR.remfirst .controlsR.clear -in .controlsR -side left -padx 2

puts "flexframe test window created. Resize the window to exercise layout." 

# Start the Tk event loop when invoked directly
if {[info exists argv0]} {vwait forever}
