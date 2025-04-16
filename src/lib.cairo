#![no_std]
use soroban_sdk::{contract, contractimpl, contracttype, symbol_short, Address, BytesN, Env, Symbol, Vec, Map};

// Define constant symbols for event topics to reduce gas costs
const JOB_CREATED: Symbol = symbol_short!("JOB_CREATED");
const MILESTONE_ADDED: Symbol = symbol_short!("MILESTONE_ADD");
const TALENT_SELECTED: Symbol = symbol_short!("TALENT_SEL");
const WORK_SUBMITTED: Symbol = symbol_short!("WORK_SUB");
const MILESTONE_APPROVED: Symbol = symbol_short!("MILEST_APPR");
const DISPUTE_RAISED: Symbol = symbol_short!("DISPUTE_RAISED");
const DISPUTE_RESOLVED: Symbol = symbol_short!("DISPUTE_RES");

// Custom data types for our contract
#[contracttype]
pub enum JobStatus {
    Created,        // Job created but no talent selected
    InProgress,     // Talent selected, work in progress
    Completed,      // All milestones completed and paid
    Disputed        // Dispute raised
}

#[contracttype]
pub enum MilestoneStatus {
    Pending,        // Work not yet submitted
    Submitted,      // Work submitted for approval
    Approved,       // Client approved, payment released
    Disputed        // Milestone is under dispute
}

#[contracttype]
pub struct Milestone {
    description: BytesN<32>,    // Short description hash
    amount: i128,               // Payment amount for this milestone
    status: MilestoneStatus,    // Current status
    submission_data: BytesN<32>,// Hash of submitted work (IPFS or similar)
}

#[contracttype]
pub struct Job {
    client: Address,            // Employer's address
    talent: Option<Address>,    // Freelancer's address (None until selected)
    title: BytesN<32>,          // Job title hash
    total_amount: i128,         // Total job budget (sum of all milestones)
    amount_paid: i128,          // Total paid so far
    status: JobStatus,          // Current job status
    milestones: Vec<Milestone>, // List of milestones
    dispute_raised: Option<Address>, // Who raised the dispute
}

#[contract]
pub struct JobMarketplaceContract;

#[contractimpl]
impl JobMarketplaceContract {
    // Creates a new job with initial milestones and locks the funds
    pub fn create_job(
        env: Env,
        client: Address,
        title: BytesN<32>,
        milestone_descriptions: Vec<BytesN<32>>,
        milestone_amounts: Vec<i128>,
    ) -> u32 {
        // Verify input lengths match
        client.require_auth();
        assert!(
            milestone_descriptions.len() == milestone_amounts.len(),
            "Descriptions and amounts must match"
        );

        // Calculate total amount and verify it's positive
        let total_amount: i128 = milestone_amounts.iter().sum();
        assert!(total_amount > 0, "Total amount must be positive");

        // Create milestones vector
        let mut milestones = Vec::new(&env);
        for (i, description) in milestone_descriptions.iter().enumerate() {
            assert!(milestone_amounts.get(i).unwrap() > &0, "Milestone amount must be positive");
            milestones.push_back(
                &env,
                Milestone {
                    description: *description,
                    amount: *milestone_amounts.get(i).unwrap(),
                    status: MilestoneStatus::Pending,
                    submission_data: BytesN::from_array(&env, &[0; 32]), // Empty initially
                },
            );
        }

        // Create the job
        let job = Job {
            client: client.clone(),
            talent: None,
            title,
            total_amount,
            amount_paid: 0,
            status: JobStatus::Created,
            milestones,
            dispute_raised: None,
        };

        // Store the job and get its ID
        let job_id = Self::store_job(&env, &job);

        // Emit event for job creation
        env.events().publish(
            (JOB_CREATED, client),
            (job_id, title, total_amount),
        );

        job_id
    }

    // Selects a talent for a job (can only be called by client)
    pub fn select_talent(env: Env, client: Address, job_id: u32, talent: Address) {
        client.require_auth();
        let mut job = Self::get_job(&env, job_id);

        // Verify job is in correct state
        assert!(
            job.status == JobStatus::Created,
            "Job must be in Created state"
        );
        assert!(job.talent.is_none(), "Talent already selected");

        // Set the talent and update status
        job.talent = Some(talent.clone());
        job.status = JobStatus::InProgress;

        // Update stored job
        Self::update_job(&env, job_id, &job);

        // Emit event
        env.events().publish(
            (TALENT_SELECTED, client),
            (job_id, talent),
        );
    }

    // Submit work for a milestone (can only be called by talent)
    pub fn submit_milestone(
        env: Env,
        talent: Address,
        job_id: u32,
        milestone_index: u32,
        submission_data: BytesN<32>,
    ) {
        talent.require_auth();
        let mut job = Self::get_job(&env, job_id);

        // Verify job is in correct state and talent matches
        assert!(
            job.status == JobStatus::InProgress,
            "Job must be in progress"
        );
        assert!(
            job.talent == Some(talent.clone()),
            "Only selected talent can submit"
        );

        // Get the milestone and verify it's pending
        let mut milestone = job.milestones.get(milestone_index).unwrap();
        assert!(
            milestone.status == MilestoneStatus::Pending,
            "Milestone must be pending"
        );

        // Update milestone status and submission data
        milestone.status = MilestoneStatus::Submitted;
        milestone.submission_data = submission_data;

        // Update the milestone in the job
        job.milestones.set(milestone_index, milestone);

        // Update stored job
        Self::update_job(&env, job_id, &job);

        // Emit event
        env.events().publish(
            (WORK_SUBMITTED, talent),
            (job_id, milestone_index, submission_data),
        );
    }

    // Approve a milestone and release payment (can only be called by client)
    pub fn approve_milestone(env: Env, client: Address, job_id: u32, milestone_index: u32) {
        client.require_auth();
        let mut job = Self::get_job(&env, job_id);

        // Verify job is in correct state and client matches
        assert!(
            job.status == JobStatus::InProgress,
            "Job must be in progress"
        );
        assert!(job.client == client, "Only job client can approve");

        // Get the milestone and verify it's submitted
        let mut milestone = job.milestones.get(milestone_index).unwrap();
        assert!(
            milestone.status == MilestoneStatus::Submitted,
            "Milestone must be submitted"
        );

        // Update milestone status
        milestone.status = MilestoneStatus::Approved;

        // Update the milestone in the job
        job.milestones.set(milestone_index, milestone);

        // Calculate payment amount
        let payment_amount = milestone.amount;
        job.amount_paid += payment_amount;

        // Check if all milestones are approved
        let all_approved = job.milestones.iter().all(|m| 
            matches!(m.status, MilestoneStatus::Approved)
        );
        
        if all_approved {
            job.status = JobStatus::Completed;
        }

        // Update stored job
        Self::update_job(&env, job_id, &job);

        // In a real implementation, here you would transfer funds to the talent
        // For this example, we just emit an event
        env.events().publish(
            (MILESTONE_APPROVED, client),
            (job_id, milestone_index, payment_amount, job.talent.unwrap()),
        );
    }

    // Raise a dispute (can be called by either party)
    pub fn raise_dispute(env: Env, caller: Address, job_id: u32, milestone_index: Option<u32>) {
        caller.require_auth();
        let mut job = Self::get_job(&env, job_id);

        // Verify caller is either client or talent
        assert!(
            caller == job.client || job.talent == Some(caller.clone()),
            "Only job parties can raise disputes"
        );

        // Verify job is in correct state
        assert!(
            job.status == JobStatus::InProgress,
            "Job must be in progress"
        );

        // If specific milestone is disputed, verify it's status
        if let Some(index) = milestone_index {
            let milestone = job.milestones.get(index).unwrap();
            assert!(
                milestone.status == MilestoneStatus::Submitted,
                "Can only dispute submitted milestones"
            );
        }

        // Set dispute flag
        job.status = JobStatus::Disputed;
        job.dispute_raised = Some(caller.clone());

        // Update stored job
        Self::update_job(&env, job_id, &job);

        // Emit event
        env.events().publish(
            (DISPUTE_RAISED, caller),
            (job_id, milestone_index),
        );
    }

    // Resolve a dispute (would be called by arbitrator in real implementation)
    pub fn resolve_dispute(
        env: Env,
        arbitrator: Address,
        job_id: u32,
        milestone_index: Option<u32>,
        decision: bool, // true = pay talent, false = refund client
    ) {
        // In a real implementation, we would verify arbitrator is authorized
        // For this example, we just require auth
        arbitrator.require_auth();
        
        let mut job = Self::get_job(&env, job_id);

        // Verify job is in disputed state
        assert!(
            job.status == JobStatus::Disputed,
            "Job must be disputed"
        );

        // Process the decision
        if decision {
            // Approve the milestone(s) and pay talent
            if let Some(index) = milestone_index {
                let mut milestone = job.milestones.get(index).unwrap();
                milestone.status = MilestoneStatus::Approved;
                job.milestones.set(index, milestone);
                job.amount_paid += milestone.amount;
            } else {
                // Approve all pending milestones
                for i in 0..job.milestones.len() {
                    let mut milestone = job.milestones.get(i).unwrap();
                    if matches!(milestone.status, MilestoneStatus::Submitted) {
                        milestone.status = MilestoneStatus::Approved;
                        job.milestones.set(i, milestone);
                        job.amount_paid += milestone.amount;
                    }
                }
            }
        } else {
            // Refund client - in real implementation would transfer funds back
            // Here we just mark milestones as pending
            if let Some(index) = milestone_index {
                let mut milestone = job.milestones.get(index).unwrap();
                milestone.status = MilestoneStatus::Pending;
                milestone.submission_data = BytesN::from_array(&env, &[0; 32]);
                job.milestones.set(index, milestone);
            } else {
                // Reset all submitted milestones
                for i in 0..job.milestones.len() {
                    let mut milestone = job.milestones.get(i).unwrap();
                    if matches!(milestone.status, MilestoneStatus::Submitted) {
                        milestone.status = MilestoneStatus::Pending;
                        milestone.submission_data = BytesN::from_array(&env, &[0; 32]);
                        job.milestones.set(i, milestone);
                    }
                }
            }
        }

        // Update job status
        let all_approved = job.milestones.iter().all(|m| 
            matches!(m.status, MilestoneStatus::Approved)
        );
        
        job.status = if all_approved {
            JobStatus::Completed
        } else {
            JobStatus::InProgress
        };

        // Clear dispute flag
        job.dispute_raised = None;

        // Update stored job
        Self::update_job(&env, job_id, &job);

        // Emit event
        env.events().publish(
            (DISPUTE_RESOLVED, arbitrator),
            (job_id, milestone_index, decision),
        );
    }

    // Helper function to store a job and return its ID
    fn store_job(env: &Env, job: &Job) -> u32 {
        // In a real implementation, this would persist to storage
        // For this example, we use a simple counter
        let mut job_count = env.storage().get(&symbol_short!("JOB_COUNT"))
            .unwrap_or(Ok(0u32))
            .unwrap();
        job_count += 1;
        env.storage().set(&symbol_short!("JOB_COUNT"), &job_count);
        env.storage().set(&Self::job_key(job_count), job);
        job_count
    }

    // Helper function to update a job
    fn update_job(env: &Env, job_id: u32, job: &Job) {
        env.storage().set(&Self::job_key(job_id), job);
    }

    // Helper function to get a job
    fn get_job(env: &Env, job_id: u32) -> Job {
        env.storage()
            .get(&Self::job_key(job_id))
            .unwrap()
            .unwrap()
    }

    // Helper function to generate storage key for a job
    fn job_key(job_id: u32) -> BytesN<32> {
        BytesN::from_array(&Env::default(), &{
            let mut arr = [0u8; 32];
            arr[..4].copy_from_slice(&job_id.to_be_bytes());
            arr
        })
    }
}