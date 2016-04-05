//
//  Tests.swift
//  Tests
//
//  Created by Matthew Yannascoli on 4/5/16.
//  Copyright © 2016 my. All rights reserved.
//

import XCTest
import CoreData
@testable import CoreDataStack

class StackTests: XCTestCase {
    struct Constants {
        static let ModelName = "TestModel"
        static let EntityName = "TestEntity"
    }

    
    func testMainContextSave() {
        
        var stack = createStack("TestDir")
        
        guard let context = stack.mainContext else {
            fatalError()
        }
        
        let entity = createTestObj(context)
        entity.testString = "BLAH"
        
        let expection = expectationWithDescription("SaveStore")
        stack.saveToDisk() {
            error in
            expection.fulfill()
        }
        
        waitForExpectationsWithTimeout(3.0, handler: nil)
        
        let fetchRequest = NSFetchRequest(entityName: Constants.EntityName)
        fetchRequest.fetchLimit = 1
        
        do {
            let result = try context.executeFetchRequest(fetchRequest).first
            let obj = result as! TestEntity
            XCTAssertEqual(obj.testString, "BLAH")
        }
        catch { }
        
        
        stack.deleteStore(andRejuvenate: false)
    }
    
    
}


//MARK: - Utilities -
extension StackTests {
    
    private func createStack(directory: String) -> CoreDataStack {
        
        let bundle = NSBundle(forClass: StackTests.self)
        let stack = CoreDataStack(
            bundle: bundle,
            modelName: Constants.ModelName,
            containerName: directory,
            inMemoryStore: false,
            logDebugOutput: true)
        
        return stack
    }
    
    private func createTestObj(context: NSManagedObjectContext) -> TestEntity {
        let entityDescription = NSEntityDescription.entityForName(Constants.EntityName, inManagedObjectContext: context)
        guard let description = entityDescription else {
            fatalError()
        }
        
        let testObj = NSManagedObject(entity: description, insertIntoManagedObjectContext: context) as? TestEntity
        guard let obj = testObj else {
            fatalError()
        }
        
        return obj
    }
}
