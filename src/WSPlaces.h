/*
 * WSPlaces.h — the sidebar's places, and the one path that is the desktop.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Portions of this file may derive from GNUstep; see THIRD-PARTY.md.
 *
 * **THE SIDEBAR'S MODEL IS DATA, NOT VIEW STATE.** A place is a title and a path; a section is a title and its
 * places. The file window's outline reads these, and the same small model answers where "Desktop" is, so the
 * application, the sidebar and a second window cannot disagree about it.
 *
 * The sections are the two this stage needs — PLACES and DEVICES. Shared and Tags are later stages' (W12 and the
 * metadata store), and a section with nothing honest to put in it is absent rather than empty.
 */
#ifndef WORKSPACE_WSPLACES_H
#define WORKSPACE_WSPLACES_H

#import <Foundation/NSArray.h>
#import <Foundation/NSObject.h>

@class NSString;

@interface WSPlace : NSObject
{
	NSString *_title;
	NSString *_path;
}
- (instancetype)initWithTitle:(NSString *)title path:(NSString *)path;
- (NSString *)title;
- (NSString *)path;
@end

@interface WSPlaceSection : NSObject
{
	NSString *_title;
	NSArray *_places;
}
- (instancetype)initWithTitle:(NSString *)title places:(NSArray *)places;
- (NSString *)title;
- (NSArray *)places;		/* NSArray<WSPlace *> */
@end

@interface WSPlaces : NSObject

/* `AGORA_DESKTOP`, or `~/Desktop`. The environment door is the suite's, exactly as the desktop window's is. */
+ (NSString *)desktopDirectory;

/* Two sections, in this order: PLACES (Desktop, Home, Applications) then DEVICES (Computer). */
+ (NSString *)applicationsDirectory;

+ (NSArray *)sections;		/* NSArray<WSPlaceSection *> */

@end

#endif /* WORKSPACE_WSPLACES_H */
