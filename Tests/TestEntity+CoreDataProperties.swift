//
//  TestEntity+CoreDataProperties.swift
//  CoreDataStack
//
//  Created by Matthew Yannascoli on 4/5/16.
//  Copyright © 2016 myfy. All rights reserved.
//
//  Choose "Create NSManagedObject Subclass…" from the Core Data editor menu
//  to delete and recreate this implementation file for your updated model.
//

import Foundation
import CoreData

extension TestEntity {

    @NSManaged var testString: String?

}
