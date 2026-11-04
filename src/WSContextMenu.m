/*
 * WSContextMenu.m — the rows, their order and their selectors.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **NO KEY EQUIVALENT IS SET, AND THAT IS NOT AN OVERSIGHT.** This tier's `-initWithTitle:action:keyEquivalent:` leaves
 * the modifier mask at ZERO (see `WSMainMenu.m`'s warning), so a context row carrying `x` would be picked by a bare x
 * key press while the menu tracks. The shortcuts belong to the menu bar, where they are already declared with their
 * masks; a context menu is the pointer's route to the same commands.
 */
#import "WSContextMenu.h"

#import <AppKit/NSMenu.h>
#import <AppKit/NSView.h>
#import <AppKit/NSWindow.h>
#import <AppKit/NSMenuItem.h>

@implementation WSContextMenu

/* **THE TRASH ADDS A ROW, AND THE MENU ASKS THE TARGET RATHER THAN TAKING A FLAG.** Every surface that raises one of
 * these menus already aims it at whoever owns the selection (`WSContextMenuCommandTarget`), and whether the window is
 * showing the Trash is that owner's fact — a file window knows, a desktop cannot be one. Asking means no caller changes
 * and no second copy of "am I in the trash" in four views. A target that does not answer at all is a probe or a plain
 * view, and gets the menu every window gets. */
+ (BOOL)cg_targetShowsTrash:(id)target
{
	return (target != nil && [target respondsToSelector:@selector(isTrashDirectory)]
		&& [target isTrashDirectory]);
}

/* ONE ROW: title, selector, and the target that will be asked whether it can answer. Nil is allowed for the target —
 * then the row is disabled by the update walk, which is the honest picture of a command nobody implements. */
+ (NSMenuItem *)cg_row:(NSString *)title action:(SEL)action target:(id)target
{
	NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""] autorelease];

	[item setTarget:target];
	return item;
}

+ (NSMenu *)menuForSingleItemWithTarget:(id)target
{
	NSMenu *menu = [[[NSMenu alloc] initWithTitle:@"Context"] autorelease];
	BOOL trash = [self cg_targetShowsTrash:target];

	/* **IN THE TRASH THE FIRST ROW IS THE WAY BACK OUT OF IT.** "Move to Trash" is not offered there: what it would do
	 * to an item already in it is the file manager talking to itself, and the reference file manager answers the same way
	 * — a trashed item's menu says Put Back and nothing about the bin it is already in. */
	if (trash) {
		[menu addItem:[self cg_row:@"Put Back" action:@selector(putBack:) target:target]];
		[menu addItem:[NSMenuItem separatorItem]];
	}
	[menu addItem:[self cg_row:@"Get Info" action:@selector(getInfo:) target:target]];
	[menu addItem:[NSMenuItem separatorItem]];
	[menu addItem:[self cg_row:@"Cut" action:@selector(cut:) target:target]];
	[menu addItem:[self cg_row:@"Copy" action:@selector(copy:) target:target]];
	[menu addItem:[NSMenuItem separatorItem]];
	[menu addItem:[self cg_row:@"Rename" action:@selector(rename:) target:target]];
	/* **COMPRESS IS A ROW HERE AS WELL AS IN THE FILE MENU.** The archive is made beside what it compressed (see
	 * `-cg_destinationBesideSelection`), which is exactly the thing a person is looking at when they right-click it; a
	 * command that is only in the menu bar is a command a person finds by accident. It sits after Rename, where the
	 * reference file manager keeps it: the rows above it change the item, this one makes something out of it. */
	[menu addItem:[self cg_row:@"Compress" action:@selector(compress:) target:target]];
	if (!trash) {
		[menu addItem:[self cg_row:@"Move to Trash" action:@selector(moveToTrash:) target:target]];
	}
	return menu;
}

/* **AND THE MENU FOR A GROUP.** The rows a group can answer are the ones that mean the same thing for one item or
 * for five: Get Info, New Folder with Selection (the reference file manager's own way to gather what was picked into a
 * folder of it), Cut, Copy and Move to Trash. RENAME IS NOT AMONG THEM — one name for many is not a command, it is a
 * question about which one was meant — so a group's menu offers what a group can actually do.
 *
 * "New Folder with Selection" is the one row here that has no menu-bar twin: the folder it makes is in the grid's own
 * directory and the selection moves into it, which is the whole point of the command. */
+ (NSMenu *)menuForMultipleItemsWithTarget:(id)target
{
	NSMenu *menu = [[[NSMenu alloc] initWithTitle:@"Context"] autorelease];
	BOOL trash = [self cg_targetShowsTrash:target];

	if (trash) {
		[menu addItem:[self cg_row:@"Put Back" action:@selector(putBack:) target:target]];
		[menu addItem:[NSMenuItem separatorItem]];
	}
	[menu addItem:[self cg_row:@"Get Info" action:@selector(getInfo:) target:target]];
	[menu addItem:[self cg_row:@"New Folder with Selection"
			   action:@selector(newFolderWithSelection:) target:target]];
	/* **AND A GROUP CAN BE ONE ARCHIVE.** "Compress" beside "New Folder with Selection" is the same idea twice: both make
	 * one thing out of what is held, and both put it where the selection is. */
	[menu addItem:[self cg_row:@"Compress" action:@selector(compress:) target:target]];
	[menu addItem:[NSMenuItem separatorItem]];
	[menu addItem:[self cg_row:@"Cut" action:@selector(cut:) target:target]];
	[menu addItem:[self cg_row:@"Copy" action:@selector(copy:) target:target]];
	[menu addItem:[NSMenuItem separatorItem]];
	if (!trash) {
		[menu addItem:[self cg_row:@"Move to Trash" action:@selector(moveToTrash:) target:target]];
	}
	return menu;
}

/* THE EMPTY GRID'S ROWS: the reference file manager's own three, and the same order. New Folder and Select All have
 * nothing to do with a selection, and Paste is the pair of the Cut a file's menu offers — so this menu is usable with
 * nothing selected and with something selected but not clicked on, which is the ordinary way a person pastes into a
 * folder. */
+ (NSMenu *)menuForBackgroundWithTarget:(id)target
{
	NSMenu *menu = [[[NSMenu alloc] initWithTitle:@"Context"] autorelease];

	[menu addItem:[self cg_row:@"New Folder" action:@selector(newFolder:) target:target]];
	[menu addItem:[NSMenuItem separatorItem]];
	[menu addItem:[self cg_row:@"Paste" action:@selector(paste:) target:target]];
	[menu addItem:[self cg_row:@"Select All" action:@selector(selectAll:) target:target]];
	return menu;
}

@end

id WSContextMenuCommandTarget(NSView *view)
{
	id delegate = [[view window] delegate];

	if (delegate != nil && [delegate respondsToSelector:@selector(newFolder:)]) {
		return delegate;
	}
	return view;
}
