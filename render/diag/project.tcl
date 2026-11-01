# Native TD project API; no hand-authored .al/.prj XML.
set db_board_root [file normalize [file join [file dirname [info script]] ..]]
set db_board render
set db_project MultimediaSystem_${db_board}_linktest
cd $db_board_root
set db_project_path $db_project.al
puts "PROJECT_PATH $db_project_path"
if {[file exists $db_project_path]} {
    eval [list open_project $db_project_path -noanalyze]
} else {
    create_project -family EG4 -device EG4S20BG256 $db_project .
}
set db_source_file [open [file join $db_board_root diag sources.txt] r]
set db_sources {}
foreach db_line [split [read $db_source_file] "\n"] {
    set db_line_trimmed [string trim $db_line]
    if {$db_line_trimmed ne ""} {
        set db_source_path $db_line_trimmed
        lappend db_sources $db_source_path
    }
}
close $db_source_file
puts "SOURCE_COUNT [llength $db_sources]"
puts "FIRST_SOURCE [lindex $db_sources 0]"
foreach db_src $db_sources {puts "ADDING <$db_src>";add_files $db_src}
open_project $db_project_path
top_module top_linktest_$db_board
# add_files/top_module persist the native project in place.
file mkdir [file join $db_board_root Runs syn]
file mkdir [file join $db_board_root Runs phy]
puts "BOARD_PROJECT_CREATED $db_project"
exit
