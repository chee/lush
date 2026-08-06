use future_form::{FutureForm, Sendable};
use sedimentree_core::{
    blob::Blob,
    collections::Set,
    fragment::Fragment,
    id::SedimentreeId,
    loose_commit::{id::CommitId, LooseCommit},
};
use sedimentree_fs_storage::{FsStorage, FsStorageError};
use subduction_core::storage::traits::Storage;
use subduction_crypto::verified_meta::VerifiedMeta;
use tokio::sync::mpsc;

#[derive(Clone, Debug)]
pub(crate) struct StoredRecord<T> {
    pub(crate) meta: T,
    pub(crate) blob: Blob,
}

#[derive(Clone, Debug)]
pub(crate) struct StoredBatch {
    pub(crate) sedimentree_id: SedimentreeId,
    pub(crate) commits: Vec<StoredRecord<LooseCommit>>,
    pub(crate) fragments: Vec<StoredRecord<Fragment>>,
}

impl StoredBatch {
    fn is_empty(&self) -> bool {
        self.commits.is_empty() && self.fragments.is_empty()
    }
}

#[derive(Clone, Debug)]
pub(crate) struct ObservedStorage {
    inner: FsStorage,
    stored: mpsc::UnboundedSender<StoredBatch>,
}

impl ObservedStorage {
    pub(crate) fn new(inner: FsStorage, stored: mpsc::UnboundedSender<StoredBatch>) -> Self {
        Self { inner, stored }
    }
}

impl Storage<Sendable> for ObservedStorage {
    type Error = FsStorageError;

    fn save_sedimentree_id(
        &self,
        sedimentree_id: SedimentreeId,
    ) -> <Sendable as FutureForm>::Future<'_, Result<(), Self::Error>> {
        <FsStorage as Storage<Sendable>>::save_sedimentree_id(&self.inner, sedimentree_id)
    }

    fn delete_sedimentree_id(
        &self,
        sedimentree_id: SedimentreeId,
    ) -> <Sendable as FutureForm>::Future<'_, Result<(), Self::Error>> {
        <FsStorage as Storage<Sendable>>::delete_sedimentree_id(&self.inner, sedimentree_id)
    }

    fn load_all_sedimentree_ids(
        &self,
    ) -> <Sendable as FutureForm>::Future<'_, Result<Set<SedimentreeId>, Self::Error>> {
        <FsStorage as Storage<Sendable>>::load_all_sedimentree_ids(&self.inner)
    }

    fn contains_sedimentree_id(
        &self,
        sedimentree_id: SedimentreeId,
    ) -> <Sendable as FutureForm>::Future<'_, Result<bool, Self::Error>> {
        <FsStorage as Storage<Sendable>>::contains_sedimentree_id(&self.inner, sedimentree_id)
    }

    fn save_loose_commit(
        &self,
        sedimentree_id: SedimentreeId,
        verified: VerifiedMeta<LooseCommit>,
    ) -> <Sendable as FutureForm>::Future<'_, Result<(), Self::Error>> {
        let stored = self.stored.clone();
        let record = StoredRecord {
            meta: verified.payload().clone(),
            blob: verified.blob().clone(),
        };
        Sendable::from_future(async move {
            <FsStorage as Storage<Sendable>>::save_loose_commit(
                &self.inner,
                sedimentree_id,
                verified,
            )
            .await?;
            let _ = stored.send(StoredBatch {
                sedimentree_id,
                commits: vec![record],
                fragments: Vec::new(),
            });
            Ok(())
        })
    }

    fn list_commit_ids(
        &self,
        sedimentree_id: SedimentreeId,
    ) -> <Sendable as FutureForm>::Future<'_, Result<Set<CommitId>, Self::Error>> {
        <FsStorage as Storage<Sendable>>::list_commit_ids(&self.inner, sedimentree_id)
    }

    fn load_loose_commits(
        &self,
        sedimentree_id: SedimentreeId,
    ) -> <Sendable as FutureForm>::Future<'_, Result<Vec<VerifiedMeta<LooseCommit>>, Self::Error>>
    {
        <FsStorage as Storage<Sendable>>::load_loose_commits(&self.inner, sedimentree_id)
    }

    fn load_loose_commit_metas(
        &self,
        sedimentree_id: SedimentreeId,
    ) -> <Sendable as FutureForm>::Future<'_, Result<Vec<LooseCommit>, Self::Error>> {
        <FsStorage as Storage<Sendable>>::load_loose_commit_metas(&self.inner, sedimentree_id)
    }

    fn load_loose_commit(
        &self,
        sedimentree_id: SedimentreeId,
        commit_id: CommitId,
    ) -> <Sendable as FutureForm>::Future<'_, Result<Option<VerifiedMeta<LooseCommit>>, Self::Error>>
    {
        <FsStorage as Storage<Sendable>>::load_loose_commit(&self.inner, sedimentree_id, commit_id)
    }

    fn delete_loose_commit(
        &self,
        sedimentree_id: SedimentreeId,
        commit_id: CommitId,
    ) -> <Sendable as FutureForm>::Future<'_, Result<(), Self::Error>> {
        <FsStorage as Storage<Sendable>>::delete_loose_commit(
            &self.inner,
            sedimentree_id,
            commit_id,
        )
    }

    fn delete_loose_commits(
        &self,
        sedimentree_id: SedimentreeId,
    ) -> <Sendable as FutureForm>::Future<'_, Result<(), Self::Error>> {
        <FsStorage as Storage<Sendable>>::delete_loose_commits(&self.inner, sedimentree_id)
    }

    fn save_fragment(
        &self,
        sedimentree_id: SedimentreeId,
        verified: VerifiedMeta<Fragment>,
    ) -> <Sendable as FutureForm>::Future<'_, Result<(), Self::Error>> {
        let stored = self.stored.clone();
        let record = StoredRecord {
            meta: verified.payload().clone(),
            blob: verified.blob().clone(),
        };
        Sendable::from_future(async move {
            <FsStorage as Storage<Sendable>>::save_fragment(&self.inner, sedimentree_id, verified)
                .await?;
            let _ = stored.send(StoredBatch {
                sedimentree_id,
                commits: Vec::new(),
                fragments: vec![record],
            });
            Ok(())
        })
    }

    fn load_fragment(
        &self,
        sedimentree_id: SedimentreeId,
        fragment_head: CommitId,
    ) -> <Sendable as FutureForm>::Future<'_, Result<Option<VerifiedMeta<Fragment>>, Self::Error>>
    {
        <FsStorage as Storage<Sendable>>::load_fragment(&self.inner, sedimentree_id, fragment_head)
    }

    fn list_fragment_ids(
        &self,
        sedimentree_id: SedimentreeId,
    ) -> <Sendable as FutureForm>::Future<'_, Result<Set<CommitId>, Self::Error>> {
        <FsStorage as Storage<Sendable>>::list_fragment_ids(&self.inner, sedimentree_id)
    }

    fn load_fragments(
        &self,
        sedimentree_id: SedimentreeId,
    ) -> <Sendable as FutureForm>::Future<'_, Result<Vec<VerifiedMeta<Fragment>>, Self::Error>>
    {
        <FsStorage as Storage<Sendable>>::load_fragments(&self.inner, sedimentree_id)
    }

    fn load_fragment_metas(
        &self,
        sedimentree_id: SedimentreeId,
    ) -> <Sendable as FutureForm>::Future<'_, Result<Vec<Fragment>, Self::Error>> {
        <FsStorage as Storage<Sendable>>::load_fragment_metas(&self.inner, sedimentree_id)
    }

    fn delete_fragment(
        &self,
        sedimentree_id: SedimentreeId,
        fragment_head: CommitId,
    ) -> <Sendable as FutureForm>::Future<'_, Result<(), Self::Error>> {
        <FsStorage as Storage<Sendable>>::delete_fragment(
            &self.inner,
            sedimentree_id,
            fragment_head,
        )
    }

    fn delete_fragments(
        &self,
        sedimentree_id: SedimentreeId,
    ) -> <Sendable as FutureForm>::Future<'_, Result<(), Self::Error>> {
        <FsStorage as Storage<Sendable>>::delete_fragments(&self.inner, sedimentree_id)
    }

    fn save_batch(
        &self,
        sedimentree_id: SedimentreeId,
        commits: Vec<VerifiedMeta<LooseCommit>>,
        fragments: Vec<VerifiedMeta<Fragment>>,
    ) -> <Sendable as FutureForm>::Future<'_, Result<usize, Self::Error>> {
        let stored = self.stored.clone();
        let batch = StoredBatch {
            sedimentree_id,
            commits: commits
                .iter()
                .map(|verified| StoredRecord {
                    meta: verified.payload().clone(),
                    blob: verified.blob().clone(),
                })
                .collect(),
            fragments: fragments
                .iter()
                .map(|verified| StoredRecord {
                    meta: verified.payload().clone(),
                    blob: verified.blob().clone(),
                })
                .collect(),
        };
        Sendable::from_future(async move {
            let count = <FsStorage as Storage<Sendable>>::save_batch(
                &self.inner,
                sedimentree_id,
                commits,
                fragments,
            )
            .await?;
            if !batch.is_empty() {
                let _ = stored.send(batch);
            }
            Ok(count)
        })
    }
}
