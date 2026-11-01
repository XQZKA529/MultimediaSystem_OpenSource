# Native TD project API; no hand-authored .al/.prj XML.
set db_board_root [file normalize [file join [file dirname [info script]] ..]]
set db_board render
set db_project MultimediaSystem_$db_board
cd $db_board_root
set db_project_path $db_project.al
puts "PROJECT_PATH $db_project_path"
if {[file exists $db_project_path]} {
    eval [list open_project $db_project_path -noanalyze]
} else {
    create_project -family EG4 -device EG4S20BG256 $db_project .
}
set db_source_file [open [file join $db_board_root build sources.txt] r]
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
top_module top_$db_board
# Persist the known working build settings for native GUI Reset/Launch.
# Otherwise the GUI silently uses an empty default strategy instead of run.ps1.
set_param -run syn_1 gate map_mode area_prior
set_param -run syn_1 rtl infer_fsm off
set_user_params -run syn_1 -params {{gate add_map_lut_struct high} {gate multi_thread_mapping partition}}
# Match the measured saturation area build: retain vendor medium placement
# defaults instead of the older high-effort expansion, and use its seed.
foreach {db_step db_key db_value} {
    place effort medium
    place opt_timing medium
    place logic_level_opt off
    place post_place_opt medium
    route post_route_opt medium
    route effort routability
    route fix_hold on
    place seed 4
} {
    set_param -run phy_1 $db_step $db_key $db_value
}
set_user_params -run phy_1 -params {{place effort medium} {place opt_timing medium} {place logic_level_opt off} {place post_place_opt medium} {route post_route_opt medium} {route effort routability} {route fix_hold on} {place seed 4}}
# Keep the native default script: Reset regenerates it using the saved strategy.
set db_f [open $db_project_path r]
set db_project_xml [read $db_f]
close $db_f
regsub -all { useDefaultScript="false"} $db_project_xml {} db_project_xml
set db_f [open $db_project_path w]
puts -nonewline $db_f $db_project_xml
close $db_f
open_project $db_project_path -noanalyze
# add_files/top_module persist the native project in place.
file mkdir [file join $db_board_root Runs syn]
file mkdir [file join $db_board_root Runs phy]
puts "BOARD_PROJECT_CREATED $db_project"
exit
