/*
 * WSContextMenu.h — the menu a right-click raises: what can be done to the item under the pointer.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **IT IS ONE MENU BECAUSE THE DESKTOP AND A FILE WINDOW OFFER THE SAME COMMANDS.** The rows are the reference file
 * manager's, in its order and with its separators, and each one sends a selector — nothing here knows how any of them
 * is implemented, so both surfaces build the same menu and answer only what they can.
 *
 * **AND THERE ARE THREE MENUS, BECAUSE A POINTER IS OVER ONE OF THREE THINGS.** Over an icon that is alone, the rows are
 * about THAT item (Get Info, Cut, Copy, Rename, Move to Trash); over an icon that is one of several held, they are about
 * the GROUP (the same commands minus Rename, plus New Folder with Selection); over the empty grid, they are about the
 * folder the grid shows (New Folder, Paste, Select All). A group's rows have no single subject to rename and a folder's
 * rows have none at all, so the click's own answer to "what is under me" picks the menu rather than one menu pretending
 * to fit every case.
 *
 * **A ROW THE TARGET DOES NOT ANSWER IS DRAWN GREY, WHICH IS THE MENU BAR'S OWN CONVENTION** (`WSMainMenu.m` records
 * it): `-[NSMenu update]` asks the item's target before the menu tracks, and a row whose command has no implementation
 * yet is grey rather than absent. So `Get Info` is a row today and a command when W8 lands, and the menu keeps
 * its shape either way; the other four are answered by both icon surfaces.
 */
#ifndef WORKSPACE_WSCONTEXTMENU_H
#define WORKSPACE_WSCONTEXTMENU_H

#import <Foundation/NSObject.h>

@class NSMenu;
@class NSView;

@interface WSContextMenu : NSObject
/* The menu for ONE item, every row targeted at `target` — the view the click landed in, which is also the thing that
 * knows which item is selected. */
+ (NSMenu *)menuForSingleItemWithTarget:(id)target;

/* **AND THE MENU FOR SEVERAL** — the commands that mean the same thing for a set as for one. */
+ (NSMenu *)menuForMultipleItemsWithTarget:(id)target;

/* **AND THE MENU FOR NOTHING AT ALL** — the grid's own background, where a click lands on no icon. Its rows are about the
 * DIRECTORY rather than about a selected thing: make one, bring something in, take everything. */
+ (NSMenu *)menuForBackgroundWithTarget:(id)target;

/* **WHO A SURFACE'S MENU IS AIMED AT.** A grid that implements its own commands is its own target; a LIST or a COLUMN
 * surface has none of them, and the window that owns the selection does (see `WSFileWindowController`'s shared commands).
 * So the target is the window's delegate when it answers `-newFolder:` — the one command every file window has — and the
 * view itself otherwise, which is what a probe building a view on its own gets. */
id WSContextMenuCommandTarget(NSView *view);
@end

#endif /* WORKSPACE_WSCONTEXTMENU_H */
