/*
 * WSGetInfoWindowController.h — the inspector a Get Info opens, one per thing asked about.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **THE WINDOW IS THE REFERENCE FILE MANAGER'S, IN SIX COLLAPSIBLE SECTIONS**: General, More Info, Name & Extension,
 * Comments, Preview, and Sharing & Permissions. Each section is a grey band with a triangle that folds it, and the
 * window scrolls when they do not all fit — which on a desktop display they do not.
 *
 * **THREE OF THE SIX WRITE SOMETHING, AND EVERY ONE OF THE THREE WRITES TO THE FILE OR TO THE FOLDER'S OWN SIDECAR.**
 * The name field renames the item through `WSFileOperations` (the same validation and the same rename the views use);
 * the Locked box sets the owner's write bit, which is what a person means by locked on a file system with no user
 * immutable flag; and the comments box is stored in the enclosing folder's `.agora` plist under the item's name, which
 * is where this tier already keeps what a person decided about a name. Everything else is what `WSItemInfo` measured.
 *
 * **ONE WINDOW PER SUBJECT, REUSED.** Asking again for something already inspected brings that window forward and
 * re-reads it, rather than stacking a second copy of the same facts — which is what the reference file manager does and
 * what a person expects of a window that is about a thing rather than about a click.
 */
#ifndef WORKSPACE_WSGETINFOWINDOWCONTROLLER_H
#define WORKSPACE_WSGETINFOWINDOWCONTROLLER_H

#import <AppKit/NSTableView.h>
#import <AppKit/NSWindow.h>
#import <AppKit/NSWindowController.h>

@class NSButton;
@class NSImageView;
@class NSTextField;
@class NSTextView;
@class WSItemInfo;
@class WSMetadataStore;

NS_ASSUME_NONNULL_BEGIN

@interface WSGetInfoWindowController : NSWindowController <NSWindowDelegate, NSTableViewDataSource,
							  NSTableViewDelegate>
{
	WSItemInfo *_info;			/* RETAINED */
	WSMetadataStore *_store;		/* RETAINED: the enclosing folder's sidecar, for the comments */
	NSString *_commentsName;		/* COPIED: the name the comment is filed under, which a rename changes */
	NSView *_documentView;		/* RETAINED by the scroll view; the sections' container */
	NSArray *_sections;			/* RETAINED: WSInfoSectionView, one per section */
	NSImageView *_headerIcon;		/* RETAINED by the document view */
	NSTextField *_headerName;
	NSTextField *_headerDetail;
	NSTextField *_headerSize;
	NSTextField *_kindValue;
	NSTextField *_sizeValue;
	NSTextField *_whereValue;
	NSTextField *_createdValue;
	NSTextField *_modifiedValue;
	NSTextField *_lastOpenedValue;
	NSButton *_sharedButton;
	NSButton *_lockedButton;
	NSTextField *_nameField;
	NSTextView *_commentsView;
	NSImageView *_previewView;
	NSTextField *_permissionSummary;
	NSTableView *_permissionTable;
	NSArray *_permissions;			/* RETAINED: NSArray<WSItemPermission *>, the table's rows */
}

/* **THE DOOR A COMMAND USES.** The same paths again reuses the window that is already open on them; different paths
 * make a new one. Nil for an empty array. */
+ (nullable instancetype)infoWindowForPaths:(NSArray *)paths;

/* The windows currently on the glass, oldest first — the probe's door to "did a second Get Info stack a second window". */
+ (NSArray *)cg_openInfoWindows;

- (nullable instancetype)initWithPaths:(NSArray *)paths;

- (WSItemInfo *)info;
- (NSArray *)paths;
- (BOOL)cg_isShowingPaths:(NSArray *)paths;

/* Re-read every fact from the file system and put it on the glass. Called when the window is brought forward, so a
 * window left open on a folder that has since been written says what is true now. */
- (void)reload;
- (void)orderFront;

/* The window's own doors, for a probe: what a section's value field says, in the order the window shows them. */
- (NSTextField *)cg_kindValue;
- (NSTextField *)cg_sizeValue;
- (NSTextField *)cg_whereValue;
- (NSTextField *)cg_createdValue;
- (NSTextField *)cg_modifiedValue;
- (NSTextField *)cg_lastOpenedValue;
- (NSTextField *)cg_nameField;
- (NSTextField *)cg_permissionSummary;
- (NSTableView *)cg_permissionTable;
- (NSTextView *)cg_commentsView;
- (NSImageView *)cg_previewView;
- (NSButton *)cg_lockedButton;
- (NSUInteger)cg_sectionCount;
/* Which sections are folded, and the fold itself — the same path a click on a band takes, minus the event. */
- (BOOL)cg_isSectionCollapsedAtIndex:(NSUInteger)index;
- (void)cg_setSectionAtIndex:(NSUInteger)index collapsed:(BOOL)collapsed;

@end

NS_ASSUME_NONNULL_END

#endif /* WORKSPACE_WSGETINFOWINDOWCONTROLLER_H */
