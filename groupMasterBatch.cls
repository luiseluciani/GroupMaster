// Jonathan Hersh - jhersh@salesforce.com - Feb '11
// batch class for loading members and copying feedposts, feedcomments, feedlikes
//LL - Updates to code to support Communities

global class groupMasterBatch implements Database.Batchable<sObject>, Database.Stateful {
    global Set<ID> sourceIDs        { get; set; }
    global ID   destID              { get; set; }
    global string opType            { get; set; }
    global boolean failed           { get; set; }
    global boolean hasGroups        { get; set; }
    global boolean deleteSources    { get; set; }

    global Database.QueryLocator start(Database.BatchableContext BC){    
        failed = false;
        
        string q;
        ID[] roles = new ID[] {};
        ID[] profiles = new ID[] {};
        ID[] groups = new ID[] {};
        
        string rolePref = Schema.Sobjecttype.UserRole.getKeyPrefix();
        string proPref = Schema.Sobjecttype.Profile.getKeyPrefix();
        
        for( ID source : sourceIDs )
            if( (''+ source).substring( 0, 3 ) == proPref )
                profiles.add( source );
            else if( ('' + source).substring( 0, 3 ) == rolePref )
                roles.add( source );
            else
                groups.add( source );
                
        hasGroups = !groups.isEmpty();
        
        if( opType == groupMaster.MEMBER_OP ) {
            if( hasGroups )
                q = 'select memberid '+
                    'from collaborationgroupmember '+
                    'where collaborationgroupid IN :groups';
            else
                q = 'select id '+
                    'from user '+
                    'where isactive = true '+//and ( usertype=\'Standard\' or usertype = \'CSNOnly\' ) '+
                    'and ( '+ 
                    ( !roles.isEmpty() ? 'userroleid IN :roles ' : 'id = null ' ) +
                    ' OR '+
                    ( !profiles.isEmpty() ? 'profileid in :profiles ' : 'id = null ' ) +' ) ';
        } else if( opType == groupMaster.COPY_OP || opType == groupMaster.MERGE_OP )
            q = 'select id, createdbyid, createddate, body, type, relatedrecordid, '+
                'LinkUrl, Title, NetworkScope, IsRichText, BestCommentId, '+
                '(select createdbyid from FeedLikes), '+
                '(select feeditemid, commentbody, createdbyid, createddate, IsRichText from FeedComments) '+
                'from FeedItem '+
                'where parentid IN :groups and type <> \'TrackedChange\' '+
                'order by id asc';  
                        
        return Database.getQueryLocator(q);
    }

    global void execute(Database.BatchableContext BC, List<sObject> scope)
    {
        ID[] userIDs = new ID[] {};
        
        if( scope == null || scope.isEmpty() )
            return;
        
        // If we're copying members, extract the userids to add
        if( opType == groupMaster.MEMBER_OP ) 
        {
            CollaborationGroupMember[] toAdd = new CollaborationGroupMember[] {};
            
            for( sObject g : scope )
                userIDs.add( ID.valueof( string.valueof( g.get( ( hasGroups ? 'memberid' : 'id' ) ) ) ) );

            if( userIDs.isEmpty() )
                return;
            
            // Which of these users are already in the destination group?
            CollaborationGroupMember[] cgs = [select memberid
                from CollaborationGroupMember
                where collaborationgroupid = :destID
                and memberid IN :userIDs];
            
            Set<ID> curMembers = new Set<ID> ();
            
            for( CollaborationGroupMember cg : cgs )
                curMembers.add( cg.memberid );
                
            for( ID uID : userIDs ) 
                if( !curMembers.contains( uID ) )
                    toAdd.add( new CollaborationGroupMember( collaborationgroupid = destID, memberid = uID ) );
                
            try {
                insert toAdd;
            } catch( Exception e ) {
                failed = true;
            }
        } 
        else if( opType == groupMaster.MERGE_OP || opType == groupMaster.COPY_OP ) 
        {
            // We're copying posts! Do the parent posts first
            Map<Id,FeedItem> oldPostIdToNewPostMap = new Map<Id,FeedItem>();
            Map<Id,List<FeedComment>> oldPostIdToNewCommentsMap = new Map<Id,List<FeedComment>>();
            Map<Id,List<FeedLike>> oldPostIdToNewLikesMap = new Map<Id,List<FeedLike>>();
            FeedComment[] newComments = new FeedComment[] {};
            FeedLike[] newLikes = new FeedLike[] {};
            
            List<FeedComment> commentArray = new List<FeedComment> ();
            List<FeedLike> likeArray = new List<FeedLike> ();

            //Best Answers
            Map<Id,Id> bestAnswerCommentIdToParentMap = new Map<Id,Id>();
        
            // We cannot insert posts by users who are no longer active
            ID[] postCreators = new ID[] {};
            List<Id> relatedRecordIds = new List<Id>();

            for( sObject s : scope ) 
            {
                FeedItem fi = (FeedItem)s;
                postCreators.add( fi.createdbyid);

                //Collect list of related records
                if(fi.relatedRecordId != null)
                    relatedRecordIds.add(fi.relatedRecordId);

                //Collect best answer Feed Comment Ids
                if(fi.BestCommentId != null)
                {
                    bestAnswerCommentIdToParentMap.put(fi.bestCommentId, fi.Id);
                }
                
                if( s.getSObjects('feedlikes') != null )
                {
                    for( FeedLike fl : s.getSObjects('feedlikes') )
                    {
                        postCreators.add( fl.createdbyid );
                    }
                }
                        
                if( s.getSObjects('feedcomments') != null )
                {
                    for( FeedComment fc : s.getSObjects('feedcomments') )
                    {
                        postCreators.add( fc.createdbyid );
                    }
                }
            }

            Map<ID, User> activeCreators = new Map<ID, User> ([select id from User
                where isactive=true
                and id IN :postCreators]);

            CollaborationGroup dest = [SELECT id, NetworkId FROM CollaborationGroup WHERE id = :destID];

            //Get information of related records (content, files) in case we are doing a cross network merge
            Map<id,ContentVersion> relatedRecordsMap = new Map<id, ContentVersion> ([SELECT id, Title, FileExtension FROM ContentVersion WHERE id IN :relatedRecordIds ]);
            
            for( sObject s : scope ) 
            {   
                FeedItem fi = (FeedItem)s;
                if( !activeCreators.keySet().contains( (string) s.get('createdbyid') ) )
                    continue;

                FeedItem newPost = new FeedItem();
                
                newPost.body = fi.Body;
                newPost.type = fi.type;
                Boolean IsRichText = fi.IsRichText;

                //Files can only be referenced if they are in the same Network (Community)
                if(fi.NetworkScope ==  dest.NetworkId)
                {
                    newPost.relatedRecordId = fi.relatedrecordid;
                }
                else if(relatedRecordsMap.containsKey(fi.relatedrecordid))
                {
                    //adding message that file has been removed since we cannot reference files across
                    //Networks
                    ContentVersion cv = relatedRecordsMap.get(fi.relatedrecordid);
                    newPost.body += '<p>&nbsp;</p>[File removed: '+cv.Title+'.'+cv.FileExtension+' ]';
                    IsRichText = true;

                    //TO DO: We can try to copy files over from one Network to the other, but we
                    //will likely run into Heap Size problems for any File larger than 6 MB.
                    //A possibility could be to segment larger files into 6MB chunks.
                }

                String urlLink = fi.linkurl;
                if(urlLink != null && urlLink.contains(' '))
                    urlLink = urlLink.replace(' ','%20');
                newPost.linkURL = urlLink;
                newPost.title = fi.title;
                newPost.createddate = fi.createddate;
                newPost.createdbyid = fi.createdbyid;
                newPost.IsRichText = IsRichText;
                //Added reference to Network
                newPost.NetworkScope = dest.NetworkId;
                newPost.parentid = destID;
                
                if( newPost.type == 'ContentPost' && newPost.relatedRecordID == null )
                    newPost.type = 'TextPost';
                
                if( newPost.body == null ) {
                    if( newPost.type == 'LinkPost' )
                        newPost.body = 'posted a link.';
                    else if(newPost.type != 'QuestionPost')
                        newPost.body = 'posted a file.';
                }
                
                oldPostIdToNewPostMap.put(fi.Id,newPost);
                
                FeedLike[] likes = new FeedLike[] {};
                FeedComment[] comments = new FeedComment[] {};
                
                likeArray = new List<FeedLike>();
                if( s.getSObjects('feedlikes') != null ) {
                    for( FeedLike fl : s.getSObjects('feedlikes') ) {
                        if( !activeCreators.keySet().contains( fl.createdbyid ) )
                            continue;

                        FeedLike newFL = new FeedLike();
                        newFL.createdbyid = fl.createdbyid;
                        
                        likeArray.add( newFL );
                    }
                }
                        
                oldPostIdToNewLikesMap.put(fi.Id, likeArray);
                
                commentArray = new List<FeedComment>();
                if( s.getSObjects('feedcomments') != null )
                {
                    for( FeedComment fc : s.getSObjects('feedcomments') )
                    {
                        if( !activeCreators.keySet().contains( fc.createdbyid ) )
                            continue;

                        FeedComment newFC = new FeedComment();
                        newFC.createdbyid = fc.createdbyid;
                        newFC.commentbody = fc.commentbody;
                        newFC.createddate = fc.createddate;
                        newFC.IsRichText = fc.IsRichText;

                        if(bestAnswerCommentIdToParentMap.containsKey(fc.Id))
                        {
                            //We will use this as a flag and clear it later
                            newFC.FeedItemId = fi.Id;
                        }
                        
                        commentArray.add( newFC );
                    }
                }
                
                oldPostIdToNewCommentsMap.put(fi.Id, commentArray);
            }
                
            try {
                insert oldPostIdToNewPostMap.values();
            } catch( Exception e ) {
                failed = true;
                return;
            }
            
            ID[] fpIDs = new ID[] {};
            Map<Id, FeedComment> newPostIdToBestAnswersMap = new Map<Id, FeedComment>();
      
            // Move comments and likes to their new parents
            for(Id oldPostId : oldPostIdToNewPostMap.keySet())
            {
                Id newPostId = oldPostIdToNewPostMap.get(oldPostId).Id;

                if(oldPostIdToNewCommentsMap.containsKey(oldPostId))
                {
                    for(FeedComment fc : oldPostIdToNewCommentsMap.get(oldPostId))
                    {
                        Boolean isBestAnswer = fc.FeedItemId != null;

                        fc.FeedItemId = newPostId;
                        
                        //Best Answer?
                        if(isBestAnswer)
                        {
                            newPostIdToBestAnswersMap.put(newPostId,fc);
                        }
                        else
                        {
                            newComments.add( fc );
                        }
                    }
                }

                if(oldPostIdToNewLikesMap.containsKey(oldPostId))
                {
                    for(FeedLike fl : oldPostIdToNewLikesMap.get(oldPostId))
                    {
                        fl.feeditemid = newPostId;
                        newLikes.add( fl );
                    }
                }
                
            }
               
            //Insert regular comments 
            try {
                insert newComments;
            } catch( Exception e ) {
                failed = true;
            }

            //Insert Best Answers
            try {
                insert newPostIdToBestAnswersMap.values();
            } catch( Exception e ) {
                failed = true;
            }
            
            try {
                insert newLikes;
            } catch( Exception e ) {
                failed = true;
            }

            //Update new posts with best answer ids
            //TODO: Figure out how to do this.
            /*if(newPostIdToBestAnswersMap.size() > 0)
            {
                List<FeedItem> postsToUpdate = new List<FeedItem>();
                for(Id newPostId : newPostIdToBestAnswersMap.keySet())
                {
                    FeedComment fc = newPostIdToBestAnswersMap.get(newPostId);

                    postsToUpdate.add(new FeedItem(Id = newPostId, BestCommentId = fc.Id));
                }

                try {
                    update postsToUpdate;
                } catch( Exception e ) {
                    failed = true;
                }
            }*/
        }
    }

    global void finish(Database.BatchableContext BC) {      
        if( opType == groupMaster.MERGE_OP && deleteSources ) {
            CollaborationGroup[] cgs = [select id
                from CollaborationGroup
                where id IN :sourceIDs];
                
            try {
                delete cgs;
            } catch( Exception e ) {
                ApexPages.addMessages( e );
            }
        }    
    }
}
