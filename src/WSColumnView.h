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
@class WSItem;
@class WSItemModel;
@class WSColumnView;

@protocol WSColumnViewDelegate <NSObject>
@optional
- (void)columnView:(WSColumnView *)view openItem:(WSItem *)item;
- (void)columnViewDidChangeModel:(WSColumnView *)view;
@end

@interface WSColumnView : NSView <NSBrowserDelegate>
{
	WSItemModel *_model;			/* RETAINED: the root directory */
	id <WSColumnViewDelegate> _viewDelegate;	/* NOT RETAINED */
	NSBrowser *_browser;			/* RETAINED */
	WSColumnPreviewView *_preview;		/* RETAINED */
	NSMutableDictionary *_childModels;	/* RETAINED: path -> WSItemModel */
	NSMutableDictionary *_columnCache;	/* RETAINED: column number -> sorted WSItem array */
}
- (instancetype)initWithFrame:(NSRect)frame model:(WSItemModel *)model;

- (void)setModel:(WSItemModel *)model;
- (nullable WSItemModel *)model;

- (nullable id <WSColumnViewDelegate>)viewDelegate;
- (void)setViewDelegate:(nullable id <WSColumnViewDelegate>)delegate;

- (void)reloadData;
- (nullable WSItem *)selectedItem;
- (NSArray *)selectedItems;
- (void)openSelectedItem;

/* **THE TEST'S SEAMS.** The browser is the platform object; the preview's item and text are what "the last column's
 * preview" means to a probe. */
- (nullable NSBrowser *)cg_browser;
- (nullable WSItem *)cg_previewItem;
- (nullable NSString *)cg_previewText;

@end

#endif /* WORKSPACE_WSCOLUMNVIEW_H */
