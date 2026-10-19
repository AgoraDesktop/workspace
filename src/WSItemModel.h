/*
 * WSItemModel.h — one directory's items, and the one object every view of them reads.
 *
 * Copyright © 2026 Kyle J. Cardoza. MIT licensed — see LICENSE.
 * SPDX-License-Identifier: MIT
 *
 * THE LOAD-BEARING CLASS (WORKSPACE-PLAN.md §6): the desktop, and later the icon, list and column views, are
 * all renderings of THIS — a directory, its items, and a change stream. Four views over four enumerations is
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
@class NSString;

/* ONE ITEM: a name, the path it lives at, and whether it is a directory. The type and the icon come from Launch
 * Services and Icon Services by URL; this holds what the directory listing gave. */
@interface WSItem : NSObject
{
	NSString *_name;
	NSString *_path;
	BOOL _isDirectory;
}
- (instancetype)initWithName:(NSString *)name path:(NSString *)path isDirectory:(BOOL)isDirectory;
- (NSString *)name;
- (NSString *)path;
- (BOOL)isDirectory;
@end

@interface WSItemModel : NSObject
{
	NSString *_directory;
	NSArray *_items;
}
- (instancetype)initWithDirectory:(NSString *)directory;
- (NSString *)directory;
- (NSArray *)items;			/* NSArray<WSItem *> */
- (BOOL)reload;
@end

#endif /* WORKSPACE_WSITEMMODEL_H */
