//
//  CurrentUser.swift
//  Quality
//
//  Created by Vincent Neo on 23/4/22.
//
// https://stackoverflow.com/a/64034073

import Cocoa
import CoreServices

class User {
    
    static let current = User()
    
    private func getUser() throws -> CSIdentity {
        let query = CSIdentityQueryCreateForCurrentUser(kCFAllocatorDefault).takeRetainedValue()
        let flags = CSIdentityQueryFlags()
        guard CSIdentityQueryExecute(query, flags, nil) else { throw QueryError.queryExecutionFailed }
        
        let users = CSIdentityQueryCopyResults(query).takeRetainedValue() as! Array<CSIdentity>

        guard let currentUser = users.first else { throw QueryError.queriedWithoutResult }
        
        return currentUser
    }
    
    private func getAdminGroup() throws -> CSIdentity {
        let privilegeGroup = "admin" as CFString
        let authority = CSGetDefaultIdentityAuthority().takeRetainedValue()
        let query = CSIdentityQueryCreateForName(kCFAllocatorDefault,
                                                 privilegeGroup,
                                                 kCSIdentityQueryStringEquals,
                                                 kCSIdentityClassGroup,
                                                 authority).takeRetainedValue()
        let flags = CSIdentityQueryFlags()
        
        guard CSIdentityQueryExecute(query, flags, nil) else { throw QueryError.queryExecutionFailed }
        let groups = CSIdentityQueryCopyResults(query).takeRetainedValue() as! Array<CSIdentity>
        
        guard let adminGroup = groups.first else { throw QueryError.queriedWithoutResult }
        
        return adminGroup
    }
    
    func isAdmin() throws -> Bool {
        let user = try self.getUser()
        let group = try self.getAdminGroup()
        return CSIdentityIsMemberOfGroup(user, group)
    }
    
    enum QueryError: Error {
        case queryExecutionFailed
        case queriedWithoutResult
    }
}
