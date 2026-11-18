ScriptWidget for Linux (preview)
================================

Desktop widgets written in JavaScript and JSX. This preview shows widgets on
the desktop of Omarchy 4.5; on other desktops the command line and the
management window work, but nothing is shown on the desktop yet.

Install (for your user, no root):

    sh install.sh

It puts the programs in ~/.local/bin, starts the background service as a
systemd user unit and, on Omarchy, enables the display plugin.

Then open "ScriptWidget" from the launcher (or run scriptwidget-studio), pick
a template, and choose "Add to desktop". To move widgets, right-click the
ScriptWidget icon in the bar and turn on "Arrange widgets".

Needs, from your distribution: ICU 78 (libicu), fontconfig, FreeType, and a
Vulkan driver for the management window. Chinese, Japanese, Korean and emoji
text uses your system fonts.

Remove:

    sh uninstall.sh            keeps your widgets
    sh uninstall.sh --purge    deletes them too

Documentation: https://github.com/everettjf/scriptwidget/tree/main/docs/linux
