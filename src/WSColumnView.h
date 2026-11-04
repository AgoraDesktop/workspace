/*
 * WSColumnView.h — the file window's Column mode: an NSBrowser and the preview beside it.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **THE BROWSER IS THE NAVIGATION; THE PREVIEW IS THE LAST COLUMN.** `WSColumnView` owns an `NSBrowser` whose columns
 * are folders and rows are their items, plus a fixed preview panel at the right that shows the selected item's
 * icon, name, Kind, size and date. The preview is the rightmost column visually and stays put while the browser's
 * columns scroll horizontally; selecting a file shows its details there, and selecting a folder both loads its
 * children into the next browser column and shows the folder's own details.
 *
 * The child-folder models are `WSItemModel`s made on demand, exactly as the list view's are: the model remains one
 * directory, and every view is a consumer of it. The browser's delegate is this view; the file window's controller
 * hears about opens and model changes through `WSColumnViewDelegate`.
 */
#ifndef WORKSPACE_WSCOLUMNVIEW_H
#define WORKSPACE_WSCOLUMNVIEW_H

#import <AppKit/NSBrowser.h>
#import <AppKit/NSView.h>

@class NSMutableDictionary;
@class WSColumnPreviewView;
@class WSFileOperations;
@class WSItem;
@class WSItemModel;
@class WSColumnView;

@protocol WSColumnViewDelegate <NSObject>
@optional
- (void)columnView:(WSColumnView *)view openItem:(WSItem *)item;
- (void)columnViewDidChangeModel:(WSColumnView *)view;
/* **AND WHICH FOLDERS IT IS SHOWING CAN CHANGE WITHOUT THE MODEL CHANGING.** Selecting a row opens the column beside it,
 * and that column lists a folder the window did not have on screen a moment ago: the window watches what it shows, so it
 * has to be told. */
- (void)columnViewDidChangeVisibleDirectories:(WSColumnView *)view;
@end

@interface WSColumnView : NSView <NSBrowserDelegate>
{
	WSItemModel *_model;			/* RETAINED: the root directory */
	id <WSColumnViewDelegate> _viewDelegate;	/* NOT RETAINED */
	NSBrowser *_browser;			/* RETAINED */
	WSColumnPreviewView *_preview;		/* RETAINED */
	NSMutableDictionary *_childModels;	/* RETAINED: path -> WSItemModel */
	NSMutableDictionary *_columnCache;	/* RETAINED: column number -> sorted WSItem array */
	WSFileOperations *_fileOperations;	/* NOT RETAINED: the window's, so a drop it performs is undoable */
	/* **THE DIRECTORY A CONTEXT MENU'S COMMANDS ACT ON**, which is the one the column that was right-clicked lists —
	 * not the window's. A browser shows a chain of folders at once, so "New Folder" in the third column belongs in the
	 * third column's folder, and the window that owns the command has to be told which one the click landed in. */
	NSString *_commandDirectory;		/* RETAINED */
	/* **THE PREVIEW'S SIZE IS A WALK FOR A FOLDER, AND THE WALK IS NOT ON THE MAIN THREAD.** `_previewPath` is the item
	 * the pane is showing, so an answer about a row the person has already left is dropped rather than drawn. */
	NSString *_previewPath;			/* RETAINED */
}
- (instancetype)initWithFrame:(NSRect)frame model:(WSItemModel *)model;

- (void)setModel:(WSItemModel *)model;
- (nullable WSItemModel *)model;

- (nullable id <WSColumnViewDelegate>)viewDelegate;
- (void)setViewDelegate:(nullable id <WSColumnViewDelegate>)delegate;

/* **THE WINDOW'S OPERATIONS, SO A DROP THIS VIEW PERFORMS IS UNDOABLE.** A browser has no undo manager of its own and
 * should not grow one: the move a drop makes is the window's, and the window's Edit menu is where it is taken back. */
- (nullable WSFileOperations *)fileOperations;
- (void)setFileOperations:(nullable WSFileOperations *)operations;

/* **THE COLUMN A MENU WAS RAISED IN, SAID BEFORE THE MENU EXISTS.** The browser's right-click records the directory that
 * column lists here; every command the menu sends then asks `-cg_commandDirectory` rather than the window's folder. */
/* **THE FOLDERS THE OPEN COLUMNS ARE SHOWING**, in column order and without repeats: what a window has to watch for a
 * browser to be live. The on-screen columns are the active ones — the pool's unused slots are not showing anything. */
- (NSArray *)cg_visibleDirectories;

- (void)cg_prepareCommandsForColumn:(NSInteger)column;
- (nullable NSString *)cg_commandDirectory;

- (void)reloadData;
- (nullable WSItem *)selectedItem;
- (NSArray *)selectedItems;
- (void)openSelectedItem;

/* **THE TEST'S SEAMS.** The browser is the platform object; the preview's item and text are what "the last column's
 * preview" means to a probe. */
- (nullable NSBrowser *)cg_browser;
/* **HOW WIDE THE PREVIEW PANE IS**, so a probe measures the pane the code draws rather than a number it copied. */
+ (CGFloat)cg_previewWidth;
- (nullable WSItem *)cg_previewItem;
/* The size line the preview is showing, and the door a measured total arrives through — the same one the background
 * walk's continuation uses, so a probe can check what the pane does with a folder's total without waiting for a thread. */
- (nullable NSString *)cg_previewSizeText;
- (void)cg_setPreviewMeasuredBytes:(unsigned long long)bytes;
- (nullable NSString *)cg_previewText;

@end

#endif /* WORKSPACE_WSCOLUMNVIEW_H */
