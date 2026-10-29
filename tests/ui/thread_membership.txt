# Thread membership on a hosted server: a thread made from the composer's "+" menu is joined (in the
# sidebar); its menu mutes it and sets its notifications; Leave Thread drops it from the sidebar, and
# Join Thread from the threads browser's row menu brings it back.
wait 5
serve_join
settle 3
click 36 157
settle 3
click 410 683
settle 1
click_text "Create Thread"
settle 1
type Plans
key enter
settle 3
rclick 135 192
settle 1
expect_visible "Leave Thread"
move_text "Notification Settings"
settle 1
click_text "Nothing"
settle 2
rclick 135 192
settle 1
move_text "Mute Thread"
settle 1
click_text "For 1 Hour"
settle 2
rclick 135 192
settle 1
expect_visible "Unmute Thread"
shot build/ui-thread_membership-menu.png
click_text "Leave Thread"
settle 2
click_text "general"
settle 2
expect_not_visible "Plans"
click 879 57
settle 2
rclick_text "Plans"
settle 1
click_text "Join Thread"
settle 2
key escape
settle 1
expect_visible "Plans"
expect_served
