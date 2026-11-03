/*
 * WSItemModel.h — one directory's items, and the one object every view of them reads.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * THE LOAD-BEARING CLASS (WORKSPACE-PLAN.md §6): the desktop, and later the icon, list and column views, are
 * all renderings of THIS — a directory, its items, and a change stream. Three views over three enumerations is
 * the classic way a file-manager clone becomes four subtly different file managers, and one model is what prevents
 * it.
 *
 * THE CHANGE STREAM IS NOT WIRED YET, AND IT IS NAMED RATHER THAN IMPLIED: `-reload` re-reads the directory and
 * `libagora-watch` (F3) will call it from a stream callback. W1's desktop redraws on demand; live updates are
 * the step that adds the stream.
 */
#ifndef WORKSPACE_WSITEMMODEL_H
#define WORKSPACE_WSITEMMODEL_H

#import <Foundation/NSObject.h>

@class NSArray;
@class NSDate;
@class NSString;

/* ONE ITEM: a name, the path it lives at, whether it is a directory, and whether that directory is a PACKAGE. The
 * type and the icon come from Launch Services and Icon Services by URL; the listing supplies the name and the
 * directory bit, and the package question is asked of the AppKit on the first ask. */
@interface WSItem : NSObject
{
	NSString *_name;
	NSString *_path;
	BOOL _isDirectory;
	BOOL _isPackage;			/* read from the AppKit on first ask */
	BOOL _packageLoaded;
	NSDate *_modificationDate;	/* RETAINED, read from the file's attributes on first ask */
	unsigned long long _size;
	BOOL _attributesLoaded;
}
- (instancetype)initWithName:(NSString *)name path:(NSString *)path isDirectory:(BOOL)isDirectory;
- (NSString *)name;
- (NSString *)path;
- (BOOL)isDirectory;

/* **A PACKAGE IS A DIRECTORY THAT IS ONE THING TO A PERSON, NOT A PLACE TO BROWSE.** An application bundle is the
 * case that matters: `isDirectory` is the filesystem fact and stays true, while this says the directory is opaque —
 * a double-click OPENS it (Launch Services decides what opening a bundle means) instead of navigating into its
 * `Contents`, and the views that draw a disclosure triangle or a column make it a leaf. The answer is
 * `NSWorkspace -isFilePackageAtPath:`, which is the AppKit's own door for it, and it is asked once. */
- (BOOL)isPackage;

/* **THE ONE RULE EVERY VIEW ASKS ABOUT A DIRECTORY**: a folder is a place to browse into, and a package is not.
 * Double-clicking a browsable item navigates; double-clicking anything else opens it. A disclosure triangle and a
 * browser column are drawn for exactly the same set. Views ask this rather than re-deriving it from `isDirectory`. */
- (BOOL)isBrowsable;

/* **THE TWO FACTS THE LIST VIEW'S COLUMNS NEED, READ LAZILY.** A directory listing does not carry them, so the first
 * ask reads the item's attributes once and keeps the date and the size; an item nobody sorts or displays never pays
 * for the stat. */
- (nullable NSDate *)modificationDate;
- (unsigned long long)size;

/* Natural order: `file2` before `file10`, case-insensitively. The desktop and icon view sort by this too. */
- (NSComparisonResult)compareByName:(WSItem *)other;
+ (NSComparisonResult)naturalCompare:(NSString *)left to:(NSString *)right;
@end

@interface WSItemModel : NSObject
{
	NSString *_directory;
	NSArray *_items;
	/* **AND THE SEARCH FIELD'S QUERY, WHICH IS THE MODEL'S BECAUSE `-items` IS WHAT EVERY VIEW DRAWS FROM.** A window's
	 * content view, its status bar's count and its path bar all read this model, so a filter held in the field (or in
	 * the controller) would be a second answer to "what is in this folder". Empty or nil means no filter. */
	NSString *_nameFilter;
}
- (instancetype)initWithDirectory:(NSString *)directory;
- (NSString *)directory;
/* **THE ITEMS THIS FOLDER HOLDS — ALL OF THEM, OR THE ONES THAT MATCH `-nameFilter:`.** The filter is a
 * case-insensitive CONTAINS on the name: a search field asks a question, and a prefix match would fail `report.pdf` for
 * `port`. A view that cached its rows keeps them, so a caller that changes the filter hands the model back to the view
 * (`-setModel:`), which is the same door navigation uses. */
- (NSArray *)items;			/* NSArray<WSItem *> */
- (void)setNameFilter:(nullable NSString *)filter;
- (nullable NSString *)nameFilter;
- (BOOL)reload;
@end

#endif /* WORKSPACE_WSITEMMODEL_H */
