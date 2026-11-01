# Native TD project API; no hand-authored .al/.prj XML.
set db_board_root [file normalize [file join [file dirname [info script]] ..]]
set db_board media
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
# Persist the same defaults used by build/run.ps1 for native GUI runs.
set_param -run syn_1 gate map_mode area_prior
set_param -run syn_1 rtl infer_fsm off
set_user_params -run syn_1 -params {
    {gate add_map_lut_struct high}
    {gate multi_thread_mapping partition}
}
foreach {db_step db_key db_value} {
    place effort high
    place opt_timing high
    place logic_level_opt on
    place post_place_opt high
    route post_route_opt high
    route effort routability
    route fix_hold on
    place seed 4
} {
    set_param -run phy_1 $db_step $db_key $db_value
}
set_user_params -run phy_1 -params {
    {place aggressive_opt 20}
    {place aggr_neighbor_dist 5}
    {place enhanced_beeline_opt 3}
    {place timing_driven_mode on}
    {place shifter_opt on}
    {place crit_path_opt on}
    {route fix_hold on}
}
# Native Reset/Launch regenerates its default flow. Keep its integrated hold
# repair enabled, and persist all optimisation parameters in the native run.
# The command-line flow uses the same native route/hold order and adds final
# report/input qualification before bit generation.
set db_f [open $db_project_path r]
set db_project_xml [read $db_f]
close $db_f
regsub -all { useDefaultScript="false"} $db_project_xml {} db_project_xml
set db_f [open $db_project_path w]
puts -nonewline $db_f $db_project_xml
close $db_f
# Reload the persisted native settings.
open_project $db_project_path -noanalyze
# add_files/top_module persist the native project in place.
file mkdir [file join $db_board_root Runs syn]
file mkdir [file join $db_board_root Runs phy]
puts "BOARD_PROJECT_CREATED $db_project"
exit
