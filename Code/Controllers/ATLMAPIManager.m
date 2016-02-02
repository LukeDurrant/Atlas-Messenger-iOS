//
//  ATLMAPIManager.m
//  Atlas Messenger
//
//  Created by Kevin Coleman on 6/12/14.
//  Copyright (c) 2014 Layer, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import "ATLMAPIManager.h"

NSString *const ATLMUserDidAuthenticateNotification = @"ATLMUserDidAuthenticateNotification";
NSString *const ATLMUserDidDeauthenticateNotification = @"ATLMUserDidDeauthenticateNotification";
NSString *const ATLMApplicationDidSynchronizeParticipants = @"ATLMApplicationDidSynchronizeParticipants";

NSString *const ATLMAtlasIdentityKey = @"atlas_identity";
NSString *const ATLMAtlasIdentitiesKey = @"atlas_identities";
NSString *const ATLMAtlasIdentityTokenKey = @"identity_token";

NSString *const ATLMAtlasUserIdentifierKey = @"id";
NSString *const ATLMAtlasUserNameKey = @"name";

@interface ATLMAPIManager () <NSURLSessionDelegate>

@property (nonatomic, readwrite) LYRClient *layerClient;

@end

@implementation ATLMAPIManager

+ (instancetype)managerWithBaseURL:(NSURL *)baseURL layerClient:(LYRClient *)layerClient
{
    NSParameterAssert(baseURL);
    NSParameterAssert(layerClient);
    return [[self alloc] initWithBaseURL:baseURL layerClient:layerClient];
}

- (id)initWithBaseURL:(NSURL *)baseURL layerClient:(LYRClient *)layerClient
{
    self = [super init];
    if (self) {
        _baseURL = baseURL;
        _layerClient = layerClient;
        _URLSession = [self defaultURLSession];
    }
    return self;
}

- (id)init
{
    @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Failed to call designated initializer." userInfo:nil];
}

- (NSURLSession *)defaultURLSession
{
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.HTTPAdditionalHeaders = @{ @"Accept": @"application/json", @"X_LAYER_APP_ID": self.layerClient.appID.absoluteString };
    return [NSURLSession sessionWithConfiguration:configuration];
}

- (BOOL)resumeSession:(ATLMSession *)session error:(NSError *__autoreleasing *)error
{
    if (!session) return NO;
    return [self configureWithSession:session error:error];
}

- (void)deauthenticate
{
    if (!self.authenticatedSession) return;
    
    self.authenticatedSession = nil;
    
    [self.URLSession invalidateAndCancel];
    self.URLSession = [self defaultURLSession];
    [[NSNotificationCenter defaultCenter] postNotificationName:ATLMUserDidDeauthenticateNotification object:nil];
}

#pragma mark - Registration

- (void)registerUserWithName:(NSString*)name nonce:(NSString *)nonce completion:(void (^)(NSString *identityToken, NSError *error))completion
{
    NSParameterAssert(name);
    NSParameterAssert(nonce);
    NSParameterAssert(completion);
    
    NSString *appUUID = [[self.layerClient.appID pathComponents] lastObject];
    NSString *urlString = [NSString stringWithFormat:@"apps/%@/atlas_identities", appUUID];
    NSURL *URL = [NSURL URLWithString:urlString relativeToURL:self.baseURL];
    NSDictionary *parameters = @{
                                 @"app_id" : appUUID,
                                 @"user_id" : name,
                                 @"nonce" : nonce
                                 };
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:parameters options:0 error:nil];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    
    [[self.URLSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!response && error) {
            NSLog(@"Failed with error: %@", error);
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, error);
            });
            return;
        }
        
        NSError *serializationError;
        NSDictionary *userDetails;
        BOOL success = [ATLMHTTPResponseSerializer responseObject:&userDetails withData:data response:(NSHTTPURLResponse *)response error:&serializationError];
        if (success) {
            NSError *error;
            NSArray *userData = userDetails[ATLMAtlasIdentitiesKey];
            BOOL success = [self persistUserData:userData error:&error];
            if (!success) {
                completion(nil, error);
            }
            ATLMUser *user = [ATLMUser userFromDictionaryRepresentation:userDetails[ATLMAtlasIdentityKey]];
            ATLMSession *session = [ATLMSession sessionWithAuthenticationToken:@"atlas_auth_token" user:user];
            dispatch_async(dispatch_get_main_queue(), ^{
                NSError *sessionConfigurationError;
                BOOL success = [self configureWithSession:session error:&sessionConfigurationError];
                if (!success) {
                    completion(nil, sessionConfigurationError);
                    return;
                }
                NSString *identityToken = userDetails[ATLMAtlasIdentityTokenKey];
                completion(identityToken, nil);
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, serializationError);
            });
        }
    }] resume];
}

- (void)loadContacts
{
    NSString *appUUID = [[self.layerClient.appID pathComponents] lastObject];
    NSString *urlString = [NSString stringWithFormat:@"apps/%@/atlas_identities", appUUID];
    NSURL *URL = [NSURL URLWithString:urlString relativeToURL:self.baseURL];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    request.HTTPMethod = @"GET";
    
    [[self.URLSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!response && error) {
            NSLog(@"Failed synchronizing participants with error: %@", error);
            return;
        }
        
        NSError *serializationError;
        NSDictionary *userDetails;
        BOOL success = [ATLMHTTPResponseSerializer responseObject:&userDetails withData:data response:(NSHTTPURLResponse *)response error:&serializationError];
        if (success) {
            NSError *error;
            NSArray *userData = (NSArray *)userDetails;
            BOOL success = [self persistUserData:userData error:&error];
            if (!success) {
                NSLog(@"Failed synchronizing participants with error: %@", error);
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:ATLMApplicationDidSynchronizeParticipants object:nil];
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSLog(@"Failed synchronizing participants with error: %@", serializationError);
            });
        }
    }] resume];
}

- (BOOL)configureWithSession:(ATLMSession *)session error:(NSError **)error
{
    if (self.authenticatedSession) return YES;
    if (!session) {
        if (error) {
            *error = [NSError errorWithDomain:ATLMErrorDomain code:ATLMNoAuthenticatedSession userInfo:@{NSLocalizedDescriptionKey: @"No authenticated session."}];
            return NO;
        }
    }
    self.authenticatedSession = session;
    BOOL success = [self.persistenceManager persistSession:session error:nil];
    if (!success) {
        *error = [NSError errorWithDomain:ATLMErrorDomain code:ATLMNoAuthenticatedSession userInfo:@{NSLocalizedDescriptionKey: @"There was an error persisting the session."}];
        return NO;
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:ATLMUserDidAuthenticateNotification object:session.user];
    return YES;
}

- (BOOL)persistUserData:(NSArray *)userData error:(NSError **)error
{
    BOOL success = [self.persistenceManager persistUsers:[self usersFromResponseData:userData] error:error];
    if (success) {
        return YES;
    } else {
        return NO;
    }
}

- (NSSet *)usersFromResponseData:(NSArray *)responseData
{
    NSMutableSet *users = [NSMutableSet new];
    for (NSDictionary *dictionary in responseData) {
        ATLMUser *user = [ATLMUser userFromDictionaryRepresentation:dictionary];
        [users addObject:user];
    }
    return users;
}

@end