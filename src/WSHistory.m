/*
 * WSHistory.m — the Back/Forward stack.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Portions of this file may derive from GNUstep; see THIRD-PARTY.md.
 */
#import "WSHistory.h"

#import <Foundation/NSArray.h>
#import <Foundation/NSURL.h>

@implementation WSHistory

- (instancetype)initWithURL:(NSURL *)url
{
	self = [super init];
	if (self != nil) {
		_urls = [[NSMutableArray alloc] init];
		_index = -1;
		if (url != nil) {
			[_urls addObject:url];
			_index = 0;
		}
	}
	return self;
}

- (void)dealloc
{
	[_urls release];
	[super dealloc];
}

- (NSURL *)currentURL
{
	if (_index < 0 || _index >= (NSInteger)[_urls count]) {
		return nil;
	}
	return [_urls objectAtIndex:(NSUInteger)_index];
}

- (NSURL *)backURL
{
	if (![self canGoBack]) {
		return nil;
	}
	return [_urls objectAtIndex:(NSUInteger)(_index - 1)];
}

- (NSURL *)forwardURL
{
	if (![self canGoForward]) {
		return nil;
	}
	return [_urls objectAtIndex:(NSUInteger)(_index + 1)];
}

- (void)pushURL:(NSURL *)url
{
	NSURL *current = [self currentURL];

	if (url == nil || [url isEqual:current]) {
		return;
	}
	/* THE FORWARD STACK GOES FIRST, and only then is the new entry added: a push is a new branch from HERE. */
	if (_index + 1 < (NSInteger)[_urls count]) {
		[_urls removeObjectsInRange:NSMakeRange((NSUInteger)(_index + 1),
							[_urls count] - (NSUInteger)(_index + 1))];
	}
	[_urls addObject:url];
	_index = (NSInteger)[_urls count] - 1;
}

- (BOOL)goBack
{
	if (![self canGoBack]) {
		return NO;
	}
	_index--;
	return YES;
}

- (BOOL)goForward
{
	if (![self canGoForward]) {
		return NO;
	}
	_index++;
	return YES;
}

- (BOOL)canGoBack
{
	return _index > 0;
}

- (BOOL)canGoForward
{
	return _index >= 0 && _index + 1 < (NSInteger)[_urls count];
}

- (NSArray *)URLs
{
	return [NSArray arrayWithArray:_urls];
}

- (NSInteger)currentIndex
{
	return _index;
}

@end
