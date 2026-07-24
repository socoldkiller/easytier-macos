use time::{OffsetDateTime, format_description::well_known::Rfc3339};

use super::{
    status::{
        CertificateAvailability, CertificateFailure, CertificateOperation, CertificateStage,
        CertificateStatus,
    },
    tls::CertifiedMaterial,
};

pub struct CertificateStateMachine;

impl CertificateStateMachine {
    pub fn begin_attempt(
        status: &mut CertificateStatus,
        has_active_certificate: bool,
        active_policy_matches: bool,
        now: OffsetDateTime,
    ) {
        status.operation = if active_policy_matches {
            CertificateOperation::Renewing
        } else if has_active_certificate {
            CertificateOperation::Replacing
        } else {
            CertificateOperation::Issuing
        };
        status.stage = Some(CertificateStage::Account);
        status.last_attempt_at = Some(format_timestamp(now));
        status.next_renewal_at = None;
        status.next_attempt_at = None;
        status.failure = None;
    }

    pub fn install(status: &mut CertificateStatus, material: &CertifiedMaterial) {
        status.availability = if material.metadata.not_after > OffsetDateTime::now_utc() {
            CertificateAvailability::Valid
        } else {
            CertificateAvailability::Expired
        };
        status.operation = CertificateOperation::Idle;
        status.stage = None;
        status.not_before = Some(material.metadata.not_before_rfc3339.clone());
        status.not_after = Some(material.metadata.not_after_rfc3339.clone());
        status.active_authority = Some(material.metadata.authority);
        status.active_challenge = Some(material.metadata.challenge.kind().to_string());
        status.next_renewal_at = None;
        status.next_attempt_at = None;
        status.failure = None;
    }

    pub fn wait_for_retry(
        status: &mut CertificateStatus,
        has_valid_certificate: bool,
        failure: CertificateFailure,
        retry_at: OffsetDateTime,
    ) {
        status.availability = if has_valid_certificate {
            CertificateAvailability::Valid
        } else {
            CertificateAvailability::Unavailable
        };
        status.operation = CertificateOperation::WaitingRetry;
        status.stage = None;
        status.next_renewal_at = None;
        status.next_attempt_at = Some(format_timestamp(retry_at));
        status.failure = Some(failure);
    }

    pub fn suspend(
        status: &mut CertificateStatus,
        has_valid_certificate: bool,
        failure: CertificateFailure,
    ) {
        status.availability = if has_valid_certificate {
            CertificateAvailability::Valid
        } else {
            CertificateAvailability::Unavailable
        };
        status.operation = CertificateOperation::Suspended;
        status.stage = None;
        status.next_renewal_at = None;
        status.next_attempt_at = None;
        status.failure = Some(failure);
    }

    pub fn queue_superseded_result(status: &mut CertificateStatus, failure: CertificateFailure) {
        status.operation = CertificateOperation::Queued;
        status.stage = None;
        status.next_renewal_at = None;
        status.next_attempt_at = None;
        status.failure = Some(failure);
    }
}

fn format_timestamp(value: OffsetDateTime) -> String {
    value
        .format(&Rfc3339)
        .unwrap_or_else(|_| "unknown".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gateway::{config::CertificateAuthorityKind, status::CertificateStatus};

    fn pending_status() -> CertificateStatus {
        CertificateStatus::pending(
            "certificate".to_string(),
            vec!["example.test".to_string()],
            CertificateAuthorityKind::Letsencrypt,
            "http01".to_string(),
        )
    }

    #[test]
    fn replacement_is_distinct_from_renewal_and_initial_issuance() {
        let now = OffsetDateTime::now_utc();
        let mut status = pending_status();
        CertificateStateMachine::begin_attempt(&mut status, false, false, now);
        assert_eq!(status.operation, CertificateOperation::Issuing);

        CertificateStateMachine::begin_attempt(&mut status, true, true, now);
        assert_eq!(status.operation, CertificateOperation::Renewing);

        CertificateStateMachine::begin_attempt(&mut status, true, false, now);
        assert_eq!(status.operation, CertificateOperation::Replacing);
    }

    #[test]
    fn suspended_failure_can_keep_a_valid_certificate_serving() {
        let mut status = pending_status();
        let failure = CertificateFailure {
            source: super::super::status::FailureSource::AcmeAuthorization,
            kind: super::super::status::FailureKind::UserActionRequired,
            code: "unauthorized".to_string(),
            message: "authorization failed".to_string(),
            occurred_at: "2026-01-01T00:00:00Z".to_string(),
            retry_at: None,
            authority: Some(CertificateAuthorityKind::Letsencrypt),
            challenge: Some("HTTP-01".to_string()),
            dns_provider: None,
            acme_problem_type: None,
            http_status: Some(403),
        };
        CertificateStateMachine::suspend(&mut status, true, failure);
        assert_eq!(status.availability, CertificateAvailability::Valid);
        assert_eq!(status.operation, CertificateOperation::Suspended);
        assert!(status.next_renewal_at.is_none());
        assert!(status.next_attempt_at.is_none());
    }
}
