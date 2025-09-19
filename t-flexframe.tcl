#!/usr/bin/env tclsh
# test_flexframe.tcl - quick smoke tests for flexframe-0.1.tm

# make sure current dir is in auto_path when running from the same folder
lappend auto_path [file normalize .]
::tcl::tm::path add [file normalize .]

package require Tk
package require flexframe 0.1

wm title . "Flexframe Test (skeleton)"

# create the widget (uses global alias 'flexframe' that forwards to ::flexframe::create)
flexframe .ff -orient vertical -autoscroll 1
pack .ff -fill both -expand 1

# create some buttons (as separate widgets) and add them to the flexframe
foreach i {1 2 3 4 5 6 7 8} {
    set btn ".btn$i"
    ttk::button $btn -text "Button $i"
    # add to flexframe (append)
    .ff add $btn
}

puts "Children after adds: [.ff children]"

# test simple configure / cget
puts "Orient: [.ff cget -orient]"
.ff configure -orient horizontal
puts "Orient after reconfigure: [.ff cget -orient]"

# insert at index 0
ttk::button .ins -text "Inserted"
.ff add .ins 0
puts "Children after insert at 0: [.ff children]"

# itemconfigure example: set sticky on the inserted child
.ff itemconfigure .ins -sticky "n"
puts "Itemconfigure .ins -sticky: [.ff itemconfigure .ins]"

# clear one child
.ff clear 1
puts "Children after clear 1: [.ff children]"

# clear all (uncomment to test)
# .ff clear
# puts "Children after clear all: [.ff children]"

# keep UI open
vwait forever
