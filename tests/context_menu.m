/*
 * context_menu — the rows a right-click raises, and the commands behind them.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **THE MENU IS THE POINTER'S ROUTE TO THE COMMANDS THE MENU BAR HAS**, and the rows are the whole of it: a title, a
 * selector and the target the row is aimed at. What is checked here is that the rows name the commands they say they do,
 * that a group gets the rows a group can answer and a single item gets the ones only one item can, that the trash's menu
 * is the trash's, and that Compress is on BOTH item menus — the command a person reaches for while looking at the file.
 */
#import "WSContextMenu.h"

#import <AppKit/NSMenu.h>
#import <AppKit/NSMenuItem.h>
#import <Foundation/Foundation.h>

#include <stdio.h>

static int s_failed;

static void check(int ok, const char *name)
{
	printf("  %s   %s\n", ok ? "ok  " : "FAIL", name);
	if (!ok) {
		s_failed++;
	}
}

/* WHAT A MENU NEEDS OF A TARGET: the trash question, and nothing else — a row stores its selector and does not send it
 * until somebody clicks, so a target for a menu is a name and an answer about the bin. */
@interface AGMenuTarget : NSObject
{
	BOOL _isTrash;
	BOOL _canExtract;
}
- (instancetype)initWithTrash:(BOOL)trash;
- (instancetype)initWithTrash:(BOOL)trash canExtract:(BOOL)canExtract;
- (BOOL)isTrashDirectory;
- (BOOL)cg_selectionCanBeExtracted;
@end

@implementation AGMenuTarget
- (instancetype)initWithTrash:(BOOL)trash
{
	return [self initWithTrash:trash canExtract:NO];
}
- (instancetype)initWithTrash:(BOOL)trash canExtract:(BOOL)canExtract
{
	self = [super init];
	if (self != nil) {
		_isTrash = trash;
		_canExtract = canExtract;
	}
	return self;
}
- (BOOL)isTrashDirectory
{
	return _isTrash;
}
- (BOOL)cg_selectionCanBeExtracted
{
	return _canExtract;
}
@end

/* THE ROW TITLES IN ORDER, WITH A SEPARATOR AS AN EM DASH — the one way to see both the rows and the shape. */
static NSString *rowsOf(NSMenu *menu)
{
	NSMutableArray *titles = [[NSMutableArray alloc] init];
	NSArray *items = [menu itemArray];
	NSUInteger i;
	NSString *joined;

	for (i = 0; i < [items count]; i++) {
		NSMenuItem *item = [items objectAtIndex:i];

		[titles addObject:[item isSeparatorItem] ? @"—" : [item title]];
	}
	joined = [titles componentsJoinedByString:@" | "];
	[joined retain];
	[titles release];
	return [joined autorelease];
}

/* **A SUBMENU IS NOT A ROW WITH AN ACTION.** The Compression row carries five leaves, and what a probe wants of them is
 * that each names the format it writes and that each is the same command with that format as its tag. */
static BOOL hasCompressionLeaves(NSMenu *menu, id target)
{
	NSInteger index = [menu indexOfItemWithTitle:@"Compression"];
	NSMenuItem *row;
	NSMenu *submenu;
	NSArray *leaves;
	NSInteger format;

	if (index == NSNotFound) {
		return NO;
	}
	row = [menu itemAtIndex:index];
	submenu = (NSMenu *)[row submenu];
	if (submenu == nil || [row action] != NULL) {
		return NO;
	}
	leaves = [submenu itemArray];
	if ([leaves count] != 5) {
		return NO;
	}
	for (format = 0; format < 5; format++) {
		NSMenuItem *leaf = [leaves objectAtIndex:(NSUInteger)format];

		if ([leaf action] != @selector(compress:) || [leaf tag] != format || [leaf target] != target) {
			return NO;
		}
	}
	return YES;
}

static BOOL hasRow(NSMenu *menu, NSString *title, SEL action)
{
	NSInteger index = [menu indexOfItemWithTitle:title];

	if (index == NSNotFound) {
		return NO;
	}
	return [[menu itemAtIndex:index] action] == action;
}

int main(void)
{
	@autoreleasepool {
		AGMenuTarget *item = [[[AGMenuTarget alloc] initWithTrash:NO] autorelease];
		AGMenuTarget *trash = [[[AGMenuTarget alloc] initWithTrash:YES] autorelease];
		NSMenu *single;
		NSMenu *multiple;
		NSMenu *background;
		NSMenu *inTrash;

		setvbuf(stdout, NULL, _IONBF, 0);

		/* 1. ONE ITEM: the rows a single item can answer, in the order a person reads them. */
		single = [WSContextMenu menuForSingleItemWithTarget:item];
		printf("  (note: one item's menu is %s\n", [rowsOf(single) UTF8String]);
		check([single numberOfItems] > 0, "one item has a menu");
		check(hasRow(single, @"Get Info", @selector(getInfo:)), "it offers Get Info");
		check(hasRow(single, @"Cut", @selector(cut:)) && hasRow(single, @"Copy", @selector(copy:)),
		      "and Cut and Copy");
		check(hasRow(single, @"Rename", @selector(rename:)), "and Rename, which one name can answer");
		check(hasRow(single, @"Compression", NULL), "and Compression, which the menu bar has and the pointer now reaches");
		check(hasCompressionLeaves(single, item),
		      "with a leaf for each of the five archives, each naming its format as its tag");
		check(hasRow(single, @"Move to Trash", @selector(moveToTrash:)), "and Move to Trash");
		check([single indexOfItemWithTitle:@"Compression"] < [single indexOfItemWithTitle:@"Move to Trash"],
		      "with Compression above Move to Trash, where the reference file manager keeps it");
		{
			NSInteger index = [single indexOfItemWithTitle:@"Compression"];
			NSMenuItem *row = [single itemAtIndex:index];

			check([row target] == item, "and every row is aimed at the target the menu was built for");
			check([[row keyEquivalent] length] == 0,
			      "with no key equivalent: an unmodified letter would fire while the menu tracks");
		}

		/* 2. A GROUP: the rows a group can answer — and Rename is not one of them. */
		multiple = [WSContextMenu menuForMultipleItemsWithTarget:item];
		printf("  (note: a group's menu is %s\n", [rowsOf(multiple) UTF8String]);
		check(hasCompressionLeaves(multiple, item), "a group can be compressed, in any of the five formats");
		check(hasRow(multiple, @"New Folder with Selection", @selector(newFolderWithSelection:)),
		      "and gathered into a folder, beside it");
		check(hasRow(multiple, @"Get Info", @selector(getInfo:)), "and asked about");
		check([multiple indexOfItemWithTitle:@"Rename"] == NSNotFound,
		      "and NOT renamed: one name for many is a question, not a command");
		check(hasRow(multiple, @"Move to Trash", @selector(moveToTrash:)), "and moved to the trash");

		/* 3. THE TRASH'S OWN: Put Back first, and no row that would put it back in the bin it is in. */
		inTrash = [WSContextMenu menuForSingleItemWithTarget:trash];
		printf("  (note: the trash's menu is %s\n", [rowsOf(inTrash) UTF8String]);
		check(hasRow(inTrash, @"Put Back", @selector(putBack:)), "a trashed item's menu starts with the way back");
		check([inTrash indexOfItemWithTitle:@"Move to Trash"] == NSNotFound,
		      "and does not offer to trash it again");
		check(hasCompressionLeaves(inTrash, trash),
		      "while Compression is still there: an archive of a trashed item is a real thing to want");

		/* 3b. EXTRACT ARCHIVE IS ASKED FOR, NOT DRAWN GREY: it is about a .zip and about nothing else, so a target that
		 * says so gets the row and a target that does not never sees it. */
		{
			AGMenuTarget *archive = [[[AGMenuTarget alloc] initWithTrash:NO canExtract:YES] autorelease];
			NSMenu *withZip = [WSContextMenu menuForSingleItemWithTarget:archive];
			NSMenu *groupWithZip = [WSContextMenu menuForMultipleItemsWithTarget:archive];

			printf("  (note: an archive's menu is %s\n", [rowsOf(withZip) UTF8String]);
			check(hasRow(withZip, @"Extract Archive", @selector(extractArchive:)),
			      "a selection that can be extracted offers Extract Archive");
			check(hasRow(groupWithZip, @"Extract Archive", @selector(extractArchive:)),
			      "and a group of them does too");
			check([withZip indexOfItemWithTitle:@"Extract Archive"] == [withZip indexOfItemWithTitle:@"Get Info"] + 1,
			      "right under Get Info");
			check([single indexOfItemWithTitle:@"Extract Archive"] == NSNotFound,
			      "and a selection of folders and files never sees the row at all");
		}

		/* 4. THE BACKGROUND: a folder's own rows, and no command that is about a selection. */
		background = [WSContextMenu menuForBackgroundWithTarget:item];
		printf("  (note: the background's menu is %s\n", [rowsOf(background) UTF8String]);
		check(hasRow(background, @"New Folder", @selector(newFolder:)), "the empty grid makes a folder");
		check(hasRow(background, @"Paste", @selector(paste:)) && hasRow(background, @"Select All", @selector(selectAll:)),
		      "and pastes and selects all");
		check([background indexOfItemWithTitle:@"Compression"] == NSNotFound,
		      "and never Compression, which is about what is HELD and not about where the pointer is");
		check([background indexOfItemWithTitle:@"Extract Archive"] == NSNotFound,
		      "nor Extract Archive, for the same reason");

		printf("context_menu: %d case(s) failed\n", s_failed);
	}
	return s_failed == 0 ? 0 : 1;
}
